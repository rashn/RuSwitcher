#!/usr/bin/env swift
import AppKit

// Генерирует иконку RuSwitcher — клавиатура с RU/EN
func generateIcon(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let s = CGFloat(size)
    let ctx = NSGraphicsContext.current!.cgContext

    // Фон — скруглённый прямоугольник (macOS style)
    let bgRect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)

    // Градиент фона
    let gradient = NSGradient(colors: [
        NSColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1.0),
        NSColor(red: 0.10, green: 0.25, blue: 0.60, alpha: 1.0)
    ])!
    gradient.draw(in: bgPath, angle: -90)

    // Две стрелки ↔ (символ переключения)
    let arrowFont = NSFont.systemFont(ofSize: s * 0.18, weight: .medium)
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: arrowFont,
        .foregroundColor: NSColor(white: 1.0, alpha: 0.3)
    ]
    let arrow = "⇄"
    let arrowSize = arrow.size(withAttributes: arrowAttrs)
    arrow.draw(at: NSPoint(x: (s - arrowSize.width) / 2, y: s * 0.58), withAttributes: arrowAttrs)

    // "RU" текст (крупный, белый)
    let ruFont = NSFont.systemFont(ofSize: s * 0.32, weight: .bold)
    let ruAttrs: [NSAttributedString.Key: Any] = [
        .font: ruFont,
        .foregroundColor: NSColor.white
    ]
    let ruText = "RU"
    let ruSize = ruText.size(withAttributes: ruAttrs)
    ruText.draw(at: NSPoint(x: (s - ruSize.width) / 2, y: s * 0.25), withAttributes: ruAttrs)

    // "EN" текст (мелкий, полупрозрачный)
    let enFont = NSFont.systemFont(ofSize: s * 0.14, weight: .medium)
    let enAttrs: [NSAttributedString.Key: Any] = [
        .font: enFont,
        .foregroundColor: NSColor(white: 1.0, alpha: 0.6)
    ]
    let enText = "EN"
    let enSize = enText.size(withAttributes: enAttrs)
    enText.draw(at: NSPoint(x: (s - enSize.width) / 2, y: s * 0.12), withAttributes: enAttrs)

    img.unlockFocus()
    return img
}

func saveAsPNG(_ image: NSImage, path: String, size: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let basePath = "/Volumes/MacHome/GitHome/RuSwitcher/Assets.xcassets/AppIcon.appiconset"

// Размеры для macOS App Store
let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    let icon = generateIcon(size: size)
    saveAsPNG(icon, path: "\(basePath)/icon_\(size).png", size: size)
    print("Generated icon_\(size).png")
}

// Также сгенерируем iconset для .icns
let iconsetPath = "/Volumes/MacHome/GitHome/RuSwitcher/RuSwitcher.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in iconsetSizes {
    let icon = generateIcon(size: size)
    saveAsPNG(icon, path: "\(iconsetPath)/\(name)", size: size)
}
print("Generated iconset")
print("Done!")
