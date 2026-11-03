// Turns square artwork into a macOS-style app icon: a rounded "squircle" tile on Apple's
// 1024 × 1024 icon grid (824 × 824 tile, transparent margin, soft shadow).
// Usage: makeicon <artwork.png> <icon-1024.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: makeicon <artwork.png> <icon-1024.png>")
    exit(1)
}
let inputURL = URL(fileURLWithPath: arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: arguments[2]) as CFURL

guard let source = CGImageSourceCreateWithURL(inputURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("Could not read \(arguments[1])")
    exit(1)
}

let canvas = 1024
let tile: CGFloat = 824
let inset = (CGFloat(canvas) - tile) / 2
let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)

/// Superellipse ("squircle") outline, close to the continuous corners of macOS icons.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Could not create the drawing canvas")
    exit(1)
}
context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
let shape = squircle(in: tileRect)

// Soft shadow under the tile
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
context.addPath(shape)
context.setFillColor(CGColor(gray: 0.12, alpha: 1))
context.fillPath()
context.restoreGState()

// Artwork clipped to the tile, scaled to cover it
context.saveGState()
context.addPath(shape)
context.clip()
let width = CGFloat(artwork.width), height = CGFloat(artwork.height)
let scale = max(tile / width, tile / height)
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: tileRect.midX - width * scale / 2, y: tileRect.midY - height * scale / 2,
                                 width: width * scale, height: height * scale))
context.restoreGState()

guard let icon = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL, UTType.png.identifier as CFString, 1, nil) else {
    print("Could not prepare \(arguments[2])")
    exit(1)
}
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else {
    print("Could not write \(arguments[2])")
    exit(1)
}
print("Icon artwork written to \(arguments[2])")
