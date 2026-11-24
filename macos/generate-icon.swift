import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
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

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixelSize)
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Deep slate-to-ocean gradient background
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.25, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.78, alpha: 1.0),
        NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.96, alpha: 1.0)
    ])
    gradient?.draw(in: bgPath, angle: 55)

    // Subtle top specular highlight
    NSColor.white.withAlphaComponent(0.18).setStroke()
    bgPath.lineWidth = max(1, s * 0.012)
    bgPath.stroke()

    // Crisp Apple AirPlay Audio SF Symbol centered on the plate
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
        shadow.shadowBlurRadius = s * 0.03
        shadow.set()

        let symSize = symbol.size
        let drawRect = NSRect(
            x: (s - symSize.width) / 2,
            y: (s - symSize.height) / 2,
            width: symSize.width,
            height: symSize.height
        )
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in entries {
    guard let data = renderIcon(pixelSize: px) else {
        fputs("Failed to render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetDir.appendingPathComponent(filename))
}
