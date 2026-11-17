import Cocoa

// Script executado apenas quando AppIcon.icns não existe (ver build.sh).

/// Renderiza o ícone da aplicação em uma resolução quadrada específica (ex.: 16 a 1024 px).
func renderIcon(pixelSize: Int) -> NSBitmapImageRep? {
    let size = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
 
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Grade padrão de ícones do macOS (~80,5% do canvas centralizado)
    let inset = size * 0.0975
    let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = iconRect.width * 0.225
    let squircle = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Sombra projetada atrás do squircle
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.02),
        blur: size * 0.045,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Recorta o desenho interno no formato do squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Gradiente de fundo escuro (azul-meia-noite para índigo)
    let bgColors = [
        CGColor(red: 0.07, green: 0.09, blue: 0.17, alpha: 1.0),
        CGColor(red: 0.12, green: 0.16, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.18, green: 0.20, blue: 0.36, alpha: 1.0)
    ] as CFArray
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: iconRect.midX, y: iconRect.minY),
            end: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            options: []
        )
    }

    let center = CGPoint(x: iconRect.midX, y: iconRect.midY + iconRect.height * 0.085)

    // Brilho ambiente quente atrás do sol
    let glowColors = [
        CGColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.48),
        CGColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.18),
        CGColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.0)
    ] as CFArray
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawRadialGradient(
            glowGradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: iconRect.width * 0.46,
            options: []
        )
    }

    // Anel translúcido em volta do sol
    let ringRadius = iconRect.width * 0.245
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.setLineWidth(max(1.0, size * 0.018))
    ctx.addEllipse(in: CGRect(
        x: center.x - ringRadius,
        y: center.y - ringRadius,
        width: ringRadius * 2,
        height: ringRadius * 2
    ))
    ctx.strokePath()
    ctx.restoreGState()

    // 12 raios solares arredondados
    let rayCount = 12
    let innerRayR = iconRect.width * 0.185
    let outerRayR = iconRect.width * 0.265
    let rayWidth = max(1.2, iconRect.width * 0.034)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(rayWidth)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.86, blue: 0.42, alpha: 0.95))
    for i in 0..<rayCount {
        let angle = CGFloat(i) * (.pi * 2.0 / CGFloat(rayCount))
        ctx.move(to: CGPoint(x: center.x + cos(angle) * innerRayR, y: center.y + sin(angle) * innerRayR))
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * outerRayR, y: center.y + sin(angle) * outerRayR))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Núcleo central do sol com gradiente dourado
    let sunRadius = iconRect.width * 0.135
    let sunRect = CGRect(
        x: center.x - sunRadius,
        y: center.y - sunRadius,
        width: sunRadius * 2,
        height: sunRadius * 2
    )
    ctx.saveGState()
    ctx.addEllipse(in: sunRect)
    ctx.clip()
    let sunColors = [
        CGColor(red: 1.0, green: 0.98, blue: 0.85, alpha: 1.0),
        CGColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0),
        CGColor(red: 0.98, green: 0.58, blue: 0.12, alpha: 1.0)
    ] as CFArray
    if let sunGradient = CGGradient(colorsSpace: colorSpace, colors: sunColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            sunGradient,
            start: CGPoint(x: sunRect.midX, y: sunRect.maxY),
            end: CGPoint(x: sunRect.midX, y: sunRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Pílula de vidro inferior representando a barra de brilho do HUD
    let pillW = iconRect.width * 0.54
    let pillH = iconRect.height * 0.105
    let pillRect = CGRect(
        x: iconRect.midX - pillW / 2,
        y: iconRect.minY + iconRect.height * 0.12,
        width: pillW,
        height: pillH
    )
    let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18))
    ctx.fillPath()
    ctx.addPath(pillPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.35))
    ctx.setLineWidth(max(1.0, size * 0.006))
    ctx.strokePath()

    // Preenchimento luminoso interno da barra de brilho
    let fillInset = pillH * 0.22
    let fillW = (pillW - fillInset * 2) * 0.72
    let fillH = pillH - fillInset * 2
    let fillRect = CGRect(x: pillRect.minX + fillInset, y: pillRect.minY + fillInset, width: fillW, height: fillH)
    let fillPath = CGPath(roundedRect: fillRect, cornerWidth: fillH / 2, cornerHeight: fillH / 2, transform: nil)
    ctx.addPath(fillPath)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.90, blue: 0.50, alpha: 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    // Reflexo especular superior (efeito Liquid Glass)
    ctx.saveGState()
    let sheenRect = CGRect(
        x: iconRect.minX - iconRect.width * 0.1,
        y: iconRect.midY + iconRect.height * 0.08,
        width: iconRect.width * 1.2,
        height: iconRect.height * 0.65
    )
    ctx.addEllipse(in: sheenRect)
    ctx.clip()
    let sheenColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let sheenGrad = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            sheenGrad,
            start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.midX, y: iconRect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    // Borda interna sutil de vidro
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24))
    ctx.setLineWidth(max(1.0, size * 0.012))
    ctx.strokePath()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Empacotamento do Arquivo .icns

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

// Tamanhos e códigos OSType padrão exigidos pelo formato Apple Icon Image (.icns)
let icnsChunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 512),
    ("ic14", 1024)
]

// Monta os blocos PNG reutilizando tamanhos duplicados (32, 64, 512 e 1024)
var pngCache: [Int: Data] = [:]
var bodyData = Data()
for (code, px) in icnsChunks {
    let png: Data
    if let cached = pngCache[px] {
        png = cached
    } else {
        guard let rep = renderIcon(pixelSize: px),
              let encoded = rep.representation(using: .png, properties: [:]) else { continue }
        pngCache[px] = encoded
        png = encoded
    }
    let chunkLength = UInt32(8 + png.count).bigEndian
    bodyData.append(contentsOf: code.utf8.prefix(4))
    withUnsafeBytes(of: chunkLength) { bodyData.append(contentsOf: $0) }
    bodyData.append(png)
}

// Escreve o cabeçalho global 'icns' seguido de todos os blocos e salva em disco
var icnsData = Data()
let totalLength = UInt32(8 + bodyData.count).bigEndian
icnsData.append(contentsOf: "icns".utf8)
withUnsafeBytes(of: totalLength) { icnsData.append(contentsOf: $0) }
icnsData.append(bodyData)

try icnsData.write(to: URL(fileURLWithPath: outputPath))
print("AppIcon.icns generated at \(outputPath)")
