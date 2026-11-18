import Cocoa
import SwiftUI

// MARK: - Brilho e Tela

/// Ponteiro para `DisplayServicesGetBrightness` (framework privado), resolvido uma única vez.
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private let getBrightnessFn: GetBrightnessFn? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
}()

/// Brilho atual (0.0–1.0) do display informado.
func brightness(_ display: CGDirectDisplayID) -> Float {
    var value: Float = 0
    _ = getBrightnessFn?(display, &value)
    return value
}

/// Converte o brilho normalizado em nits estimados (curva exponencial aproximada, 1–600 nits).
func nits(_ value: Float) -> Int {
    Int((1 + 599 * pow(Double(value), 2.3)).rounded())
}

/// Tela embutida do MacBook (ou a primeira tela, com a tampa fechada) e seu ID de display.
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

// MARK: - Teclas de Brilho (CGEventTap)

private var keyTap: CFMachPort?
private var onBrightnessKey: () -> Void = {}

/// Escuta (somente leitura) as teclas de brilho no nível HID, inclusive em 0% e 100%.
/// Requer a permissão de Monitoramento de Entrada. Retorna `true` se o tap estiver ativo.
func startBrightnessKeyTap() -> Bool {
    if keyTap != nil { return true }
    guard CGPreflightListenEventAccess(),
          let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << 14, // NX_SYSDEFINED (teclas especiais)
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap = keyTap {
                    CGEvent.tapEnable(tap: tap, enable: true) // reativa se o sistema desligar o tap
                } else if let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 {
                    // data1: código da tecla nos 16 bits altos (2 = brilho +, 3 = brilho −); 0x0A = pressionada
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

// MARK: - Overlay

/// Janela transparente que exibe nits e porcentagem no canto superior direito, sem capturar cliques.
final class OverlayWindow: NSWindow {
    private let nitsLabel = OverlayWindow.label(NSRect(x: 16, y: 0, width: 100, height: 20), .left)
    private let percentLabel = OverlayWindow.label(NSRect(x: 136, y: 0, width: 100, height: 20), .right)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 24), styleMask: .borderless, backing: .buffered, defer: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView?.addSubview(nitsLabel)
        contentView?.addSubview(percentLabel)
    }

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

    /// Atualiza os textos, posiciona na tela alvo (alinhado à HUD nativa quando disponível)
    /// e agenda o fade-out 1s após a última tecla.
    func show(_ value: Float, on screen: NSScreen, hudMinX: CGFloat? = nil) {
        nitsLabel.stringValue = "\(nits(value)) nits"
        percentLabel.stringValue = "\(Int((value * 100).rounded()))%"
        let v = screen.visibleFrame
        let x = hudMinX.map { $0 + 74 } ?? (v.maxX - frame.width - 36)
        setFrameOrigin(NSPoint(x: x, y: v.maxY - frame.height - 46))
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NSAnimationContext.runAnimationGroup { $0.duration = 0; animator().alphaValue = 1 }
        orderFrontRegardless()
        perform(#selector(fadeOut), with: nil, afterDelay: 1.0)
    }

    /// Inicia o fade-out de 0.3s junto com o desaparecimento da HUD nativa.
    @objc func fadeOut() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; animator().alphaValue = 0 }) { [weak self] in
            if self?.alphaValue == 0 { self?.orderOut(nil) }
        }
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

    var body: some View {
        VStack(spacing: 18) {
            // Cabeçalho: ícone do app, nome e status
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NitsOverlay").font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(!model.keysGranted ? Color.yellow : (model.enabled ? Color.green : Color.secondary))
                            .frame(width: 7, height: 7)
                        Text(!model.keysGranted
                             ? "Autorize para ativar"
                             : (model.enabled ? "Ativo em segundo plano" : "Overlay pausado"))
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

// MARK: - AppDelegate

/// Coordena o gatilho por teclas de brilho, a janela de configuração e a presença na Dock.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = Model()
    private let overlay = OverlayWindow()
    private var window: NSWindow?
    private var target = builtInDisplay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instância única: uma segunda cópia (ex.: lançada pelo LaunchAgent) encerra imediatamente
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            return NSApp.terminate(nil)
        }

        // Menu mínimo para Cmd+W (fechar → segundo plano) e Cmd+Q (encerrar)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Fechar Janela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Encerrar NitsOverlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(appItem)

        // Atualiza a tela alvo quando monitores são conectados/desconectados
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.target = builtInDisplay()
        }

        onBrightnessKey = { [weak self] in self?.triggerOverlay() }
        refreshPermissions()

        // LSUIElement: o app inicia fora da Dock; só abre a janela se não foi lançado no login
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    /// Reabrir o app (Finder, Spotlight, Dock) mostra a janela novamente.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Ao voltar ao app (ex.: após autorizar nos Ajustes), revalida as permissões.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions()
    }

    /// Fechar a janela apenas oculta o app para o segundo plano.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    // MARK: Janela

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

    private func hideWindow() {
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func authorize() {
        if !CGRequestListenEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
    }

    // MARK: Permissões e Overlay

    /// Ativa o tap de teclas se o Monitoramento de Entrada estiver autorizado.
    private func refreshPermissions() {
        model.keysGranted = startBrightnessKeyTap()
    }

    /// Retorna o `minX` da janela da HUD nativa (`MenuBarAgent`) na tela alvo, se já estiver visível.
    private func nativeHUDMinX(on display: CGDirectDisplayID) -> CGFloat? {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let d = CGDisplayBounds(display)
        for w in windows {
            guard w[kCGWindowOwnerName as String] as? String == "MenuBarAgent",
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict),
                  r.minX >= d.midX && r.maxX <= d.maxX + 20 && r.minY < d.minY + 120 && r.height > 40 && r.height <= 200 else {
                continue
            }
            return r.minX
        }
        return nil
    }

    /// Exibe o overlay imediatamente e reatualiza após 40ms para refletir o brilho e a posição da HUD nativa.
    private func triggerOverlay() {
        guard model.enabled, let t = target else { return }
        overlay.show(brightness(t.id), on: t.screen, hudMinX: nativeHUDMinX(on: t.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.model.enabled, let t = self.target else { return }
            self.overlay.show(brightness(t.id), on: t.screen, hudMinX: self.nativeHUDMinX(on: t.id))
        }
    }
}

// MARK: - Ponto de Entrada

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
