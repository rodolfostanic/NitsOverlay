import Cocoa
import SwiftUI

// MARK: - Leitura de Brilho e Tela Alvo

/// Ponteiro para `DisplayServicesGetBrightness` (framework privado), resolvido uma única vez na inicialização.
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private let getBrightnessFn: GetBrightnessFn? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
}()

/// Lê o brilho atual (0.0–1.0) do display informado via `DisplayServices`.
func brightness(_ display: CGDirectDisplayID) -> Float {
    var value: Float = 0
    _ = getBrightnessFn?(display, &value)
    return value
}

/// Converte o brilho normalizado em nits estimados (curva exponencial aproximada, 1–600 nits).
func nits(_ value: Float) -> Int {
    Int((1 + 599 * pow(Double(value), 2.3)).rounded())
}

/// Localiza a tela embutida do MacBook (ou usa a primeira tela como fallback em modo tampa fechada)
/// para que o overlay apareça sempre no display interno, mesmo com outra tela ativa.
func builtInDisplay() -> (screen: NSScreen, id: CGDirectDisplayID)? {
    var fallback: (screen: NSScreen, id: CGDirectDisplayID)?
    for screen in NSScreen.screens {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
        let id = CGDirectDisplayID(num.uint32Value)
        if CGDisplayIsBuiltin(id) != 0 { return (screen, id) }
        if fallback == nil { fallback = (screen, id) }
    }
    return fallback
}

// MARK: - Monitoramento de Entrada (CGEventTap)

private var keyTap: CFMachPort?
private var onBrightnessKey: () -> Void = {}

/// Registra um `CGEventTap` somente leitura no nível HID (`.cghidEventTap`) para capturar as teclas
/// de brilho com 0% de uso de CPU em repouso, inclusive nos extremos de 0% e 100%.
/// Requer permissão de Monitoramento de Entrada; retorna `true` quando ativo.
func startBrightnessKeyTap() -> Bool {
    if keyTap != nil { return true }
    guard CGPreflightListenEventAccess(),
          let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << 14, // NX_SYSDEFINED (teclas especiais de mídia e brilho)
            callback: { _, type, event, _ in
                // Reativa automaticamente caso o macOS suspenda o tap por timeout ou entrada do usuário
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap = keyTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                } else if let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 {
                    // Bits 16–31 trazem o código da tecla (2 = brilho +, 3 = brilho −); 0x0A indica key-down
                    let code = (e.data1 & 0xFFFF_0000) >> 16
                    if (e.data1 & 0xFF00) >> 8 == 0x0A, code == 2 || code == 3 { onBrightnessKey() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil)
    else { return false }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    keyTap = tap
    return true
}

// MARK: - Janela Flutuante do Overlay

/// Painel flutuante transparente (`NSPanel` não ativável) que exibe nits e porcentagem sem roubar foco.
/// Usa `.nonactivatingPanel`, `.fullScreenAuxiliary` e `level = .screenSaver` (1000) para renderizar
/// acima da HUD nativa (`layer = 101`) tanto no Desktop quanto em Spaces em tela cheia.
final class OverlayWindow: NSPanel {
    private let nitsLabel = OverlayWindow.label(NSRect(x: 16, y: 0, width: 100, height: 20), .left)
    private let percentLabel = OverlayWindow.label(NSRect(x: 136, y: 0, width: 100, height: 20), .right)
    /// Chamado exatamente ao final do fade visual (0.28s) para expirar o ID da HUD nativa.
    var onFadeComplete: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 24),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver // Mantido após styleMask (evitar isFloatingPanel = true, que rebaixa para .floating)
        hidesOnDeactivate = false
        isOpaque = false
        alphaValue = 0
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView?.addSubview(nitsLabel)
        contentView?.addSubview(percentLabel)
    }

    /// Cria um rótulo branco semitransparente com sombra sutil para leitura sobre a pílula de vidro.
    private static func label(_ frame: NSRect, _ alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.frame = frame
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white.withAlphaComponent(0.95)
        label.alignment = alignment
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.4)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        label.shadow = shadow
        return label
    }

    /// Atualiza textos e posição alinhada à HUD nativa, aplica fade-in apenas se ainda não estava
    /// totalmente visível e agenda o fade-out 1s após a última tecla pressionada.
    func show(_ value: Float, on screen: NSScreen, hudRect: CGRect) {
        let needsFadeIn = !isVisible || alphaValue < 1
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        nitsLabel.stringValue = "\(nits(value)) nits"
        percentLabel.stringValue = "\(Int((value * 100).rounded()))%"
        setFrameOrigin(NSPoint(x: hudRect.minX + 74, y: screen.frame.maxY - hudRect.minY - frame.height - 46))
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        if needsFadeIn {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        }
        perform(#selector(fadeOut), with: nil, afterDelay: 1.0)
    }

    /// Anima a saída em 0.28s e agenda o encerramento pelo temporizador direto (sem depender do
    /// completionHandler do NSAnimationContext, que dispara ~285ms depois do alpha zerar).
    @objc private func fadeOut() {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.28; animator().alphaValue = 0 }
        perform(#selector(finishFade), with: nil, afterDelay: 0.28)
    }

    /// Remove o overlay da tela e notifica o fim do fade visual caso nenhum novo ajuste o tenha cancelado.
    @objc private func finishFade() {
        orderOut(nil)
        onFadeComplete?()
    }
}

// MARK: - Estado e Preferências

private let loginPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/br.com.stanic.NitsOverlay.plist")

/// Estado observável compartilhado entre a interface e o AppDelegate.
@Observable final class Model {
    var enabled = UserDefaults.standard.object(forKey: "NitsOverlayEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "NitsOverlayEnabled") }
    }
    /// Cria ou remove o LaunchAgent em ~/Library/LaunchAgents para iniciar em segundo plano no login.
    var launchAtLogin = FileManager.default.fileExists(atPath: loginPlist.path) {
        didSet {
            guard launchAtLogin != oldValue else { return }
            let fm = FileManager.default
            if launchAtLogin, let exe = Bundle.main.executablePath {
                try? fm.createDirectory(at: loginPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = ["Label": "br.com.stanic.NitsOverlay",
                                            "ProgramArguments": [exe, "--background"],
                                            "RunAtLoad": true]
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    try? data.write(to: loginPlist, options: .atomic)
                }
            } else {
                try? fm.removeItem(at: loginPlist)
            }
        }
    }
    var keysGranted = false
}

// MARK: - Interface de Configuração (Liquid Glass)

struct SettingsView: View {
    @Bindable var model: Model
    let onAuthorize: () -> Void
    let onDone: () -> Void

    private var status: (text: String, color: Color) {
        if !model.keysGranted { return ("Autorize para ativar", .yellow) }
        return model.enabled ? ("Ativo em segundo plano", .green) : ("Overlay pausado", .secondary)
    }

    var body: some View {
        VStack(spacing: 18) {
            // Cabeçalho: ícone do app, nome e status
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NitsOverlay").font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text(status.text)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Opções
            VStack(spacing: 0) {
                row("Ativar Overlay", "Exibe nits e porcentagem junto à HUD de brilho", "sun.max", .orange) {
                    Toggle("", isOn: $model.enabled).labelsHidden()
                }
                Divider().padding(.horizontal, 14)
                row("Iniciar com o Sistema", "Abre em segundo plano no login", "power", .green) {
                    Toggle("", isOn: $model.launchAtLogin).labelsHidden()
                }
                Divider().padding(.horizontal, 14)
                row("Teclas de Brilho",
                    model.keysGranted ? "Monitoramento de Entrada ativo" : "Obrigatório para detectar as teclas",
                    "keyboard", model.keysGranted ? .green : .yellow) {
                    if model.keysGranted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Autorizar", action: onAuthorize).buttonStyle(.glassProminent)
                    }
                }
            }
            .toggleStyle(.switch)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            // Rodapé
            HStack(spacing: 12) {
                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Text("Encerrar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(action: onDone) { Text("Concluir").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)

            Text("Ao concluir ou fechar, o app sai da Dock\ne continua em segundo plano.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 390)
    }

    /// Linha padrão de opção: ícone, título, subtítulo e controle à direita.
    private func row<Accessory: View>(_ title: String, _ subtitle: String, _ icon: String, _ color: Color,
                                      @ViewBuilder _ accessory: () -> Accessory) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Ciclo de Vida da Aplicação e Sincronia com a HUD

/// Gerencia a janela de configuração (e sua alternância na Dock), as permissões do sistema
/// e a exibição do overlay alinhado à janela da HUD nativa do `MenuBarAgent`.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = Model()
    private let overlay = OverlayWindow()
    private var window: NSWindow?
    private var target = builtInDisplay()
    private var attemptsLeft = 0
    private var activeHUDID: CGWindowID = 0
    private var expiredHUDID: CGWindowID = 0
    private var lastBrightness: Float = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instância única: uma segunda cópia (ex.: aberta pelo LaunchAgent) encerra imediatamente
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            return NSApp.terminate(nil)
        }

        // Menu mínimo para habilitar os atalhos padrão Cmd+W (ocultar) e Cmd+Q (encerrar)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Fechar Janela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Encerrar NitsOverlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(appItem)

        // Atualiza o display alvo quando monitores externos são conectados ou desconectados
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.target = builtInDisplay()
        }

        overlay.onFadeComplete = { [weak self] in
            guard let self else { return }
            self.expiredHUDID = self.activeHUDID
        }
        onBrightnessKey = { [weak self] in self?.triggerOverlay() }
        model.keysGranted = startBrightnessKeyTap()

        // LSUIElement mantém o app fora da Dock no boot (--background); abertura manual exibe a janela
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    /// Reabrir o app pelo Finder, Spotlight ou Dock traz a janela de configuração de volta.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Revalida a permissão de Monitoramento de Entrada ao retornar dos Ajustes do Sistema.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.keysGranted = startBrightnessKeyTap()
    }

    /// Intercepta o fechamento da janela para ocultar o app da Dock mantendo-o ativo em segundo plano.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    // MARK: Janela de Configuração

    /// Constrói (se liberada) a janela Liquid Glass, promove o app para a Dock (.regular) e ativa o foco.
    private func showWindow() {
        if window == nil {
            let view = SettingsView(
                model: model,
                onAuthorize: { [weak self] in self?.authorize() },
                onDone: { [weak self] in self?.hideWindow() }
            )
            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            let glass = NSGlassEffectView()
            glass.contentView = host
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.contentView = glass
            w.delegate = self
            w.center()
            window = w
        }
        model.launchAtLogin = FileManager.default.fileExists(atPath: loginPlist.path)
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Libera a árvore SwiftUI da memória e remove o ícone da Dock (.accessory).
    private func hideWindow() {
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Solicita o Monitoramento de Entrada e abre os Ajustes caso ainda falte autorização manual.
    private func authorize() {
        if !CGRequestListenEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        model.keysGranted = startBrightnessKeyTap()
    }

    // MARK: Detecção da HUD Nativa e Disparo do Overlay

    /// Retorna `kCGWindowNumber` e `CGRect` da pílula de brilho do `MenuBarAgent` no display embutido.
    /// Filtra por `layer == 101` (descarta a barra de menus) e só ignora `expiredHUDID` quando
    /// `allowExpired` é falso (sem mudança real de brilho), evitando reabrir o overlay na cauda
    /// zumbi de ~275ms sem bloquear ajustes reais feitos durante o fade-out.
    private func nativeHUD(on display: CGDirectDisplayID, allowExpired: Bool) -> (id: CGWindowID, rect: CGRect)? {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let d = CGDisplayBounds(display)
        for w in windows {
            guard w[kCGWindowOwnerName as String] as? String == "MenuBarAgent",
                  w[kCGWindowLayer as String] as? Int == 101,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  allowExpired || id != expiredHUDID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict),
                  d.intersects(r), r.width > 200, r.width <= 480, r.height > 40, r.height <= 220 else {
                continue
            }
            return (id, r)
        }
        return nil
    }

    /// Agenda uma verificação única (com debounce) para exibir o overlay assim que a HUD nativa surgir.
    private func triggerOverlay() {
        guard model.enabled else { return }
        attemptsLeft = 15
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(checkHUD), object: nil)
        perform(#selector(checkHUD), with: nil, afterDelay: 0.02)
    }

    /// Verifica a HUD nativa a cada 20ms (até 300ms): se o brilho mudou, aceita inclusive o ID
    /// recém-expirado (que o `MenuBarAgent` reativa); se o brilho ficou travado (0%/100%), exige
    /// um novo `CGWindowID` para não exibir o overlay sozinho durante a cauda invisível.
    @objc private func checkHUD() {
        guard model.enabled, let t = target else { return }
        let current = brightness(t.id)
        let brightnessChanged = abs(current - lastBrightness) > 0.0005
        if let hud = nativeHUD(on: t.id, allowExpired: brightnessChanged) {
            lastBrightness = current
            activeHUDID = hud.id
            expiredHUDID = 0
            overlay.show(current, on: t.screen, hudRect: hud.rect)
        } else if attemptsLeft > 0 {
            attemptsLeft -= 1
            perform(#selector(checkHUD), with: nil, afterDelay: 0.02)
        }
    }
}

// MARK: - Ponto de Entrada

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
