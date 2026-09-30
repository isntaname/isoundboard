#!/usr/bin/env swift
// Draws the Soundboard app icon and builds AppIcon.icns.
//
//   swift Resources/Icon/make-icon.swift
//
// A 3×3 grid of sampler pads on a graphite body, with the centre pad lit
// amber and carrying a small waveform. Follows the macOS (Big Sur and later)
// icon grid: an 824-pt rounded square centred on a 1024-pt canvas.
import AppKit
import CoreGraphics

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
let icns = here.appendingPathComponent("AppIcon.icns")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// A continuous-corner rounded rectangle (superellipse-like), as macOS icons use.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.28          // how far the curve reaches along each edge
    let c = radius * k
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: x0 + c, y: y0))
    p.addLine(to: CGPoint(x: x1 - c, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + c),
               control1: CGPoint(x: x1 - c * 0.25, y: y0),
               control2: CGPoint(x: x1, y: y0 + c * 0.25))
    p.addLine(to: CGPoint(x: x1, y: y1 - c))
    p.addCurve(to: CGPoint(x: x1 - c, y: y1),
               control1: CGPoint(x: x1, y: y1 - c * 0.25),
               control2: CGPoint(x: x1 - c * 0.25, y: y1))
    p.addLine(to: CGPoint(x: x0 + c, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - c),
               control1: CGPoint(x: x0 + c * 0.25, y: y1),
               control2: CGPoint(x: x0, y: y1 - c * 0.25))
    p.addLine(to: CGPoint(x: x0, y: y0 + c))
    p.addCurve(to: CGPoint(x: x0 + c, y: y0),
               control1: CGPoint(x: x0, y: y0 + c * 0.25),
               control2: CGPoint(x: x0 + c * 0.25, y: y0))
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, in r: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY),
                           end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.restoreGState()
}

/// Draws in a 1024×1024, y-up coordinate space.
func draw(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 185)

    // Drop shadow under the whole tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x262A33))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite body.
    linear(ctx, bodyPath, top: rgb(0x454B58), bottom: rgb(0x1E2229), in: body)

    // Bevel: light along the top edge, fading out.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.addPath(squircle(body.insetBy(dx: 3, dy: 3), radius: 182))
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let bevel = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.0)] as CFArray,
                           locations: [0, 0.5])!
    ctx.drawLinearGradient(bevel, start: CGPoint(x: 512, y: body.maxY),
                           end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // Pads.
    let inset: CGFloat = 92, gap: CGFloat = 34
    let size = (body.width - inset * 2 - gap * 2) / 3

    // Glow from the lit centre pad, drawn first so it spills evenly onto the
    // body between the pads on every side.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let centre = CGPoint(x: body.midX, y: body.midY)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFA41F, 0.55), rgb(0xFFA41F, 0.0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: centre, startRadius: size * 0.4,
                           endCenter: centre, endRadius: size * 1.35, options: [])
    ctx.restoreGState()
    for row in 0..<3 {
        for col in 0..<3 {
            let x = body.minX + inset + CGFloat(col) * (size + gap)
            let y = body.minY + inset + CGFloat(row) * (size + gap)
            let face = CGRect(x: x, y: y + 6, width: size, height: size - 6)
            let lip = CGRect(x: x, y: y, width: size, height: size - 6)
            let lit = row == 1 && col == 1

            ctx.addPath(squircle(lip, radius: 38))
            ctx.setFillColor(lit ? rgb(0xC26A00) : rgb(0x15181D))
            ctx.fillPath()

            linear(ctx, squircle(face, radius: 38),
                   top: lit ? rgb(0xFFD58A) : rgb(0x5C6270),
                   bottom: lit ? rgb(0xFFA41F) : rgb(0x434856), in: face)

            if lit {
                // Waveform on the lit pad.
                let heights: [CGFloat] = [0.26, 0.52, 0.80, 0.52, 0.26]
                let barW: CGFloat = 20, barGap: CGFloat = 14
                let total = barW * 5 + barGap * 4
                for (i, h) in heights.enumerated() {
                    let bh = (size - 6) * h * 0.72
                    let bx = face.midX - total / 2 + CGFloat(i) * (barW + barGap)
                    let bar = CGRect(x: bx, y: face.midY - bh / 2, width: barW, height: bh)
                    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
                    ctx.setFillColor(rgb(0x3A2300, 0.85))
                    ctx.fillPath()
                }
            }
        }
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path)")
