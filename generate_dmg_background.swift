#!/usr/bin/env swift
import AppKit
import CoreGraphics

let width: CGFloat = 660
let height: CGFloat = 400

// Create bitmap context
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let ctx = context.cgContext

// --- Background gradient (dark blue-gray) ---
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let gradientColors = [
    CGColor(colorSpace: colorSpace, components: [0.12, 0.13, 0.18, 1.0])!,
    CGColor(colorSpace: colorSpace, components: [0.18, 0.20, 0.28, 1.0])!,
    CGColor(colorSpace: colorSpace, components: [0.12, 0.13, 0.18, 1.0])!,
]
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0.0, 0.5, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// --- Subtle grid pattern ---
ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.03])!)
ctx.setLineWidth(0.5)
for x in stride(from: 0, through: width, by: 30) {
    ctx.move(to: CGPoint(x: x, y: 0))
    ctx.addLine(to: CGPoint(x: x, y: height))
}
for y in stride(from: 0, through: height, by: 30) {
    ctx.move(to: CGPoint(x: 0, y: y))
    ctx.addLine(to: CGPoint(x: width, y: y))
}
ctx.strokePath()

// --- Title "RuSwitcher" at top ---
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.95, alpha: 1.0),
]
let title = "RuSwitcher" as NSString
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 55), withAttributes: titleAttrs)

// --- Subtitle ---
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.68, alpha: 1.0),
]
let subtitle = "Keyboard layout switcher for macOS" as NSString
let subSize = subtitle.size(withAttributes: subAttrs)
subtitle.draw(at: NSPoint(x: (width - subSize.width) / 2, y: height - 80), withAttributes: subAttrs)

// --- Arrow in the middle (between icon positions) ---
// App icon will be at x=170, Applications at x=490
// Arrow goes from ~260 to ~400

let arrowY: CGFloat = 185  // vertical center of icons area
let arrowStartX: CGFloat = 255
let arrowEndX: CGFloat = 405

// Arrow body - gradient line
ctx.setLineCap(.round)
ctx.setLineWidth(3)

// Draw dashed arrow body
let dashColor = CGColor(colorSpace: colorSpace, components: [0.4, 0.5, 0.9, 0.6])!
ctx.setStrokeColor(dashColor)
ctx.setLineDash(phase: 0, lengths: [8, 6])
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 15, y: arrowY))
ctx.strokePath()

// Arrow head
ctx.setLineDash(phase: 0, lengths: [])
ctx.setFillColor(dashColor)
ctx.move(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 20, y: arrowY + 12))
ctx.addLine(to: CGPoint(x: arrowEndX - 20, y: arrowY - 12))
ctx.closePath()
ctx.fillPath()

// --- "Drag to install" text under arrow ---
let dragAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.65, alpha: 0.8),
]
let dragText = "Drag to install  •  Перетащите для установки" as NSString
let dragSize = dragText.size(withAttributes: dragAttrs)
dragText.draw(at: NSPoint(x: (width - dragSize.width) / 2, y: arrowY - 45), withAttributes: dragAttrs)

// --- Glow circles behind icon positions ---
func drawGlow(at center: CGPoint, radius: CGFloat, color: [CGFloat]) {
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: color + [0.15])!,
        CGColor(colorSpace: colorSpace, components: color + [0.0])!,
    ]
    let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glowGradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// Glow behind app icon area (left)
drawGlow(at: CGPoint(x: 170, y: 195), radius: 90, color: [0.3, 0.4, 0.9])

// Glow behind Applications area (right)
drawGlow(at: CGPoint(x: 490, y: 195), radius: 90, color: [0.3, 0.7, 0.5])

// --- Version badge at bottom ---
let verAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.4, green: 0.42, blue: 0.5, alpha: 0.6),
]
let verText = "v2.0.0  •  MIT License  •  github.com/rashn/RuSwitcher" as NSString
let verSize = verText.size(withAttributes: verAttrs)
verText.draw(at: NSPoint(x: (width - verSize.width) / 2, y: 15), withAttributes: verAttrs)

// --- Save ---
NSGraphicsContext.current = nil
let pngData = rep.representation(using: .png, properties: [:])!
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_background.png"
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Generated: \(outputPath) (\(Int(width))x\(Int(height)))")
