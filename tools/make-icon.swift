// Draws the Dead Air app icon: a Signal Orange flatline (the dead air) that breaks
// into a voice waveform, on a near-black tile. Writes a 1024 px PNG to the path given.
//   xcrun swiftc -O tools/make-icon.swift -o build/make-icon && build/make-icon build/icon-1024.png
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let orange = rgb(0xE85D00)

// Apple's macOS icon grid: an 824 px tile centered on 1024, corner radius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the tile, as the system icons have.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x161412)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// A little light from the top, so it isn't a flat slab.
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x24201C), rgb(0x121110)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Faint scope grid.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.05)); ctx.setLineWidth(2)
for i in stride(from: tile.minX + 68.67, to: tile.maxX, by: 68.67) {
    ctx.move(to: CGPoint(x: i, y: tile.minY)); ctx.addLine(to: CGPoint(x: i, y: tile.maxY))
    ctx.move(to: CGPoint(x: tile.minX, y: i)); ctx.addLine(to: CGPoint(x: tile.maxX, y: i))
}
ctx.strokePath()

// The flatline, then the waveform: bars as tall as a spoken phrase.
let mid = 512.0
let lineW = 30.0
ctx.setStrokeColor(orange); ctx.setLineCap(.butt); ctx.setLineWidth(lineW)
ctx.move(to: CGPoint(x: 205, y: mid)); ctx.addLine(to: CGPoint(x: 430, y: mid)); ctx.strokePath()

let heights: [Double] = [70, 170, 300, 220, 380, 250, 140, 200, 90]
let gap = 46.0
for (i, h) in heights.enumerated() {
    let x = 470 + Double(i) * gap
    // fade the tail a little, so the voice trails off
    let a = i < 6 ? 1.0 : 1.0 - Double(i - 5) * 0.18
    ctx.setStrokeColor(rgb(0xE85D00, a))
    ctx.move(to: CGPoint(x: x, y: mid - h / 2)); ctx.addLine(to: CGPoint(x: x, y: mid + h / 2)); ctx.strokePath()
}

// The ON AIR dot, top right.
ctx.setFillColor(orange)
ctx.fillEllipse(in: CGRect(x: 760, y: 760, width: 52, height: 52))
ctx.setFillColor(rgb(0xE85D00, 0.25))
ctx.fillEllipse(in: CGRect(x: 744, y: 744, width: 84, height: 84))
ctx.restoreGState()

// A hairline edge, so it holds up on a dark Dock.
ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
