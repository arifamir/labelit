// Draws LabelIt's app icon and writes every size macOS needs into an asset catalog icon set.
//
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset docs/icon.png
//
// The second argument, optional, is a rounded preview (the shape macOS gives it) for the README.
//
// The design: a golden luggage tag with written lines (the name LabelIt gives a file) and a sparkle (the on-device
// AI), on deep indigo. Drawn as vectors at each size, edge to edge: macOS 26 applies the rounded shape and the shadow
// itself, and puts icons that draw their own (the older 824-point grid) inside a gray frame.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A squircle (superellipse) like macOS's icon shape, rather than a plain rounded rectangle.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / exponent)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / exponent)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// A luggage tag pointing left: a rectangle whose left end comes to a blunt point, all corners rounded.
func tagShape(width w: CGFloat, height h: CGFloat, point p: CGFloat, radius r: CGFloat) -> CGPath {
    let corners = [CGPoint(x: 0, y: h / 2), CGPoint(x: p, y: h), CGPoint(x: w, y: h),
                   CGPoint(x: w, y: 0), CGPoint(x: p, y: 0)]
    let path = CGMutablePath()
    let start = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
    path.move(to: start)
    for i in 1...corners.count {
        path.addArc(tangent1End: corners[i % corners.count], tangent2End: corners[(i + 1) % corners.count], radius: r)
    }
    path.closeSubpath()
    return path
}

/// A four-pointed sparkle with curved sides.
func sparkle(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let pinch = r * 0.16
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + pinch, y: c.y + pinch))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + pinch, y: c.y - pinch))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - pinch, y: c.y - pinch))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - pinch, y: c.y + pinch))
    path.closeSubpath()
    return path
}

func drawIcon(in context: CGContext) {
    // The art is laid out on an 824-point body centred in the canvas; scaled up so the body fills it edge to edge.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let fill = canvas / body.width
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.scaleBy(x: fill, y: fill)
    context.translateBy(x: -canvas / 2, y: -canvas / 2)
    let shape = CGPath(rect: body, transform: nil)

    // Background: deep indigo to violet, lit from the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: nil, colors: [color(0x5A4BF5), color(0x3B2BB8), color(0x24166E)] as CFArray,
                                locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A soft glow behind the tag.
    let glow = CGGradient(colorsSpace: nil, colors: [color(0x8F7BFF, 0.55), color(0x8F7BFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 500), startRadius: 0,
                               endCenter: CGPoint(x: 540, y: 500), endRadius: 420, options: [])
    context.restoreGState()

    // The tag, tilted so it points up and to the left.
    let w: CGFloat = 560, h: CGFloat = 330, point: CGFloat = 150
    context.saveGState()
    context.translateBy(x: 540, y: 485)
    context.rotate(by: 32 * .pi / 180)
    context.translateBy(x: -w / 2, y: -h / 2)

    let tag = tagShape(width: w, height: h, point: point, radius: 46)
    // The string, from the hole out past the tag's point.
    let hole = CGPoint(x: point * 0.72, y: h / 2)
    let string = CGMutablePath()
    string.move(to: hole)
    string.addCurve(to: CGPoint(x: -95, y: h / 2 + 95), control1: CGPoint(x: -20, y: h / 2 - 50),
                    control2: CGPoint(x: -95, y: h / 2 + 20))
    context.setStrokeColor(color(0xF4EFFF, 0.9))
    context.setLineWidth(15)
    context.setLineCap(.round)
    context.addPath(string)
    context.strokePath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0B0630, 0.45))
    context.addPath(tag)
    context.setFillColor(color(0xF7B733))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tag)
    context.clip()
    let gold = CGGradient(colorsSpace: nil, colors: [color(0xFFE08A), color(0xFBC342), color(0xF0A01E)] as CFArray,
                          locations: [0, 0.5, 1])!
    context.drawLinearGradient(gold, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    context.restoreGState()

    // A thin highlight along the tag's edge.
    context.addPath(tag)
    context.setStrokeColor(color(0xFFF3C4, 0.7))
    context.setLineWidth(5)
    context.strokePath()

    // The eyelet.
    context.addEllipse(in: CGRect(x: hole.x - 34, y: hole.y - 34, width: 68, height: 68))
    context.setFillColor(color(0xFFF6DA))
    context.fillPath()
    context.addEllipse(in: CGRect(x: hole.x - 19, y: hole.y - 19, width: 38, height: 38))
    context.setFillColor(color(0x3B2BB8))
    context.fillPath()

    // Written lines: the new name.
    context.setFillColor(color(0x9A5B05, 0.85))
    let lines: [(x: CGFloat, y: CGFloat, length: CGFloat)] = [(205, 205, 280), (205, 145, 210), (205, 85, 140)]
    for line in lines {
        context.addPath(CGPath(roundedRect: CGRect(x: line.x, y: line.y - 14, width: line.length, height: 28),
                               cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
    }
    context.restoreGState()

    // Sparkles: the on-device AI.
    context.saveGState()
    context.setShadow(offset: .zero, blur: 24, color: color(0xFFFFFF, 0.6))
    context.setFillColor(color(0xFFFFFF))
    context.addPath(sparkle(center: CGPoint(x: 742, y: 742), radius: 96))
    context.fillPath()
    context.setFillColor(color(0xFFFFFF, 0.85))
    context.addPath(sparkle(center: CGPoint(x: 838, y: 618), radius: 42))
    context.fillPath()
    context.restoreGState()
}

func render(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(size: points * scale), to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))

let catalog = output.deletingLastPathComponent()
if !FileManager.default.fileExists(atPath: catalog.appendingPathComponent("Contents.json").path) {
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
}
print("Wrote \(images.count) icon sizes to \(output.path)")

// The preview: the edge-to-edge art clipped to the squircle macOS draws it in, with the usual margin.
if CommandLine.arguments.count > 2 {
    let size = 512
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(squircle(in: body))
    context.clip()
    // Draw the full-canvas art into the body.
    context.translateBy(x: body.minX, y: body.minY)
    context.scaleBy(x: body.width / canvas, y: body.height / canvas)
    drawIcon(in: context)
    let preview = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
    writePNG(context.makeImage()!, to: preview)
    print("Wrote the preview to \(preview.path)")
}
