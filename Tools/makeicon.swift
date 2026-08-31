// Draws Audify's app icon and writes an .iconset directory.
//
// Generating the icon from code keeps a binary asset out of the repository and means the icon can
// never drift from the accent colour used in the UI.
//
// Usage: swift Tools/makeicon.swift <output.iconset>
//        swift Tools/makeicon.swift --extension <output-dir>   (browser extension PNGs)

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let extensionMode = arguments.first == "--extension"
let outputPath = extensionMode
    ? (arguments.count > 1 ? arguments[1] : "Extension/icons")
    : (arguments.first ?? "build/AppIcon.iconset")

/// macOS icons are drawn inside a rounded square with a ~10% margin on each side.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = rect.width * 0.235

    // Squircle-ish background with a vertical gradient in Audify's accent range.
    let path = CGPath(
        roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )
    context.saveGState()
    context.addPath(path)
    context.clip()

    let colors = [
        CGColor(red: 0.30, green: 0.56, blue: 1.00, alpha: 1),
        CGColor(red: 0.13, green: 0.32, blue: 0.86, alpha: 1),
    ]
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
    }

    // Three level bars of different heights: the mixer idea, readable down to 16pt.
    let barCount = 3
    let barWidth = rect.width * 0.115
    let spacing = rect.width * 0.105
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    let heights: [CGFloat] = [0.34, 0.60, 0.44]
    var x = rect.midX - totalWidth / 2

    context.setFillColor(CGColor(gray: 1, alpha: 0.96))
    for index in 0..<barCount {
        let height = rect.height * heights[index]
        let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        context.addPath(
            CGPath(
                roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                transform: nil
            )
        )
        context.fillPath()
        x += barWidth + spacing
    }

    // Knob on the tallest bar, so the icon reads as "adjustable" rather than "playing".
    let knobRadius = barWidth * 0.92
    let knobCenter = CGPoint(
        x: rect.midX, y: rect.midY + rect.height * heights[1] * 0.5 - knobRadius * 1.75
    )
    context.setFillColor(CGColor(red: 0.09, green: 0.22, blue: 0.62, alpha: 1))
    context.addEllipse(
        in: CGRect(
            x: knobCenter.x - knobRadius, y: knobCenter.y - knobRadius,
            width: knobRadius * 2, height: knobRadius * 2
        )
    )
    context.fillPath()

    context.restoreGState()
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        throw NSError(domain: "makeicon", code: 1)
    }
    representation.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "makeicon", code: 2)
    }
    try data.write(to: url)
}

let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

if extensionMode {
    // Chrome wants plain square PNGs at four sizes.
    for size in [16, 32, 48, 128] {
        let image = drawIcon(size: CGFloat(size))
        try writePNG(
            image, to: outputURL.appendingPathComponent("icon\(size).png"), pixelSize: size
        )
    }
    print("Wrote 4 extension icons to \(outputPath)")
    exit(0)
}

// The exact set of names `iconutil` expects.
let variants: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    let image = drawIcon(size: CGFloat(pixels))
    try writePNG(
        image, to: outputURL.appendingPathComponent("\(variant.name).png"), pixelSize: pixels
    )
}

print("Wrote \(variants.count) icon variants to \(outputPath)")
