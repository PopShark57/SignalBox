// Generates Signalbox.iconset and AppIcon.icns from code, with no third-party
// dependencies, so the application icon is reproducible from source.
//
//     swift Design/GenerateAppIcon.swift [output-directory]
//
// The mark is a railway signal head: a capsule housing carrying three aspects,
// of which exactly one is lit. It states the name directly, and it matches what
// the application does — report one honest aspect from the evidence it has,
// rather than a score summed across everything.
//
// Sizes at or below 64px are drawn from a heavier variant: larger lenses, more
// contrast, and no glow, because a soft glow turns to grey mud once a lamp is
// three pixels wide.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colour

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha
    ])!
}

private func ramp(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - Geometry

/// A superellipse, which matches the continuous-corner plate shape macOS uses
/// far more closely than a circular-cornered rounded rectangle does.
private func squircle(center: CGPoint, radius: CGFloat, exponent: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let segments = 1024
    let power = 2 / exponent
    for step in 0...segments {
        let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(segments)
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x + radius * (cosine < 0 ? -1 : 1) * pow(abs(cosine), power)
        let y = center.y + radius * (sine < 0 ? -1 : 1) * pow(abs(sine), power)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

private func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                             width: 2 * radius, height: 2 * radius), transform: nil)
}

private func capsule(center: CGPoint, width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
           cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
}

// MARK: - Fills

private func fill(_ context: CGContext, _ path: CGPath, _ gradient: CGGradient,
                  from start: CGPoint, to end: CGPoint, alpha: CGFloat = 1) {
    context.saveGState()
    context.setAlpha(alpha)
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func fillRadial(_ context: CGContext, _ path: CGPath, _ gradient: CGGradient,
                        center: CGPoint, radius: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func stroke(_ context: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width)
    context.setStrokeColor(color)
    context.strokePath()
    context.restoreGState()
}

// MARK: - Icon

/// Draws the icon into a 1024-unit design space scaled to `pixels`.
private func drawIcon(pixels: Int) -> CGImage? {
    guard let context = CGContext(data: nil,
                                  width: pixels,
                                  height: pixels,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let small = pixels <= 64
    let center = CGPoint(x: 512, y: 512)

    // Plate — 824pt on the 1024pt canvas, per Apple's macOS icon grid.
    let plate = squircle(center: center, radius: 412)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: srgb(0x000000, 0.36))
    context.addPath(plate)
    context.setFillColor(srgb(0x1B2A39))
    context.fillPath()
    context.restoreGState()

    fill(context, plate, ramp([srgb(0x44648A), srgb(0x2A4059), srgb(0x152232)], [0, 0.5, 1]),
         from: CGPoint(x: 200, y: 924), to: CGPoint(x: 824, y: 100))
    stroke(context, plate, srgb(0xFFFFFF, 0.16), 5)

    // Signal housing. The lenses nearly fill its width, leaving only a bezel —
    // a wide housing with large margins reads as a blob rather than a signal.
    let lensRadius: CGFloat = small ? 110 : 92
    let spacing: CGFloat = small ? 232 : 224
    let bezel: CGFloat = small ? 35 : 34
    let housingWidth = 2 * lensRadius + 2 * bezel
    let housingHeight = 2 * spacing + 2 * lensRadius + 2 * bezel
    let housing = capsule(center: center, width: housingWidth, height: housingHeight)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: srgb(0x000000, 0.45))
    context.addPath(housing)
    context.setFillColor(srgb(0x0B1219))
    context.fillPath()
    context.restoreGState()
    fill(context, housing, ramp([srgb(0x1B2938), srgb(0x0D151E), srgb(0x05090D)], [0, 0.55, 1]),
         from: CGPoint(x: 512 - housingWidth / 2, y: 512 + housingHeight / 2),
         to: CGPoint(x: 512 + housingWidth / 2, y: 512 - housingHeight / 2))
    stroke(context, housing, srgb(0xFFFFFF, small ? 0.22 : 0.16), small ? 8 : 7)

    let lensCenters = [
        CGPoint(x: 512, y: 512 + spacing),
        CGPoint(x: 512, y: 512),
        CGPoint(x: 512, y: 512 - spacing)
    ]

    for (index, lensCenter) in lensCenters.enumerated() {
        let lens = circle(lensCenter, lensRadius)
        guard index == 0 else {
            // Unlit lenses read as dark glass: a cool fill, a faint rim, and a
            // soft highlight along the top edge.
            fill(context, lens, ramp([srgb(0x33495F), srgb(0x18242F)], [0, 1]),
                 from: CGPoint(x: lensCenter.x, y: lensCenter.y + lensRadius),
                 to: CGPoint(x: lensCenter.x, y: lensCenter.y - lensRadius))
            stroke(context, lens, srgb(0xFFFFFF, small ? 0.2 : 0.14), small ? 7 : 6)
            if !small {
                fill(context,
                     circle(CGPoint(x: lensCenter.x, y: lensCenter.y + lensRadius * 0.34), lensRadius * 0.62),
                     ramp([srgb(0xFFFFFF, 0.12), srgb(0xFFFFFF, 0)], [0, 1]),
                     from: CGPoint(x: lensCenter.x, y: lensCenter.y + lensRadius),
                     to: CGPoint(x: lensCenter.x, y: lensCenter.y - lensRadius * 0.2))
            }
            continue
        }

        // A lit lamp throws a little light onto its surroundings, but the glow
        // is kept tight — a wide one turns to grey haze once it is downscaled.
        if !small {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 26, color: srgb(0xF3A63A, 0.55))
            context.addPath(lens)
            context.setFillColor(srgb(0xF0A032))
            context.fillPath()
            context.restoreGState()
        }

        fillRadial(context, lens,
                   ramp([srgb(0xFFF3D6), srgb(0xFFC96E), srgb(0xE8931F)], [0, 0.55, 1]),
                   center: CGPoint(x: lensCenter.x - lensRadius * 0.2, y: lensCenter.y + lensRadius * 0.26),
                   radius: lensRadius * 1.5)
        stroke(context, lens, srgb(0xFFE7B4, small ? 0.5 : 0.32), small ? 6 : 5)

        if !small {
            fill(context,
                 circle(CGPoint(x: lensCenter.x - lensRadius * 0.3, y: lensCenter.y + lensRadius * 0.38), lensRadius * 0.3),
                 ramp([srgb(0xFFFFFF, 0.55), srgb(0xFFFFFF, 0)], [0, 1]),
                 from: CGPoint(x: lensCenter.x, y: lensCenter.y + lensRadius * 0.68),
                 to: CGPoint(x: lensCenter.x, y: lensCenter.y + lensRadius * 0.08))
        }
    }

    return context.makeImage()
}

// MARK: - Output

private func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create a PNG destination at \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "GenerateAppIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
    }
}

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
let iconsetDirectory = outputDirectory.appendingPathComponent("Signalbox.iconset")

try? FileManager.default.removeItem(at: iconsetDirectory)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

let entries: [(name: String, pixels: Int)] = [
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

for entry in entries {
    guard let image = drawIcon(pixels: entry.pixels) else {
        FileHandle.standardError.write(Data("Could not render \(entry.name)\n".utf8))
        exit(1)
    }
    try write(image, to: iconsetDirectory.appendingPathComponent(entry.name))
}

// A standalone 1024px render, for review outside the .icns container.
if let preview = drawIcon(pixels: 1024) {
    try write(preview, to: outputDirectory.appendingPathComponent("AppIcon-preview.png"))
}

FileHandle.standardOutput.write(Data("\(iconsetDirectory.path)\n".utf8))
