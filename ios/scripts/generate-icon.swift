#!/usr/bin/env swift
// Code-native vector drawing. Run from ios/embryo: swift scripts/generate-icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                         bytesPerRow: size * 4, space: colorSpace,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot create icon drawing context.")
}
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}
cg.setAllowsAntialiasing(true)
cg.setFillColor(color(0.055, 0.09, 0.12))
cg.fill(CGRect(x: 0, y: 0, width: size, height: size))

// A quiet orbit around a single living seed.
cg.setStrokeColor(color(0.35, 0.68, 0.67, 0.28))
cg.setLineWidth(20)
cg.strokeEllipse(in: CGRect(x: 164, y: 164, width: 696, height: 696))
cg.setStrokeColor(color(0.35, 0.68, 0.67, 0.12))
cg.setLineWidth(8)
cg.strokeEllipse(in: CGRect(x: 230, y: 230, width: 564, height: 564))

cg.saveGState()
cg.translateBy(x: 512, y: 512)
cg.rotate(by: -.pi / 7)
let seed = CGPath(roundedRect: CGRect(x: -165, y: -212, width: 330, height: 424),
                  cornerWidth: 165, cornerHeight: 165, transform: nil)
cg.setFillColor(color(0.94, 0.56, 0.36))
cg.addPath(seed)
cg.fillPath()
cg.setFillColor(color(1, 0.82, 0.55))
cg.fillEllipse(in: CGRect(x: -88, y: -56, width: 176, height: 176))
cg.restoreGState()

for (x, y, radius) in [(786.0, 726.0, 41.0), (235.0, 302.0, 23.0)] {
    cg.setFillColor(color(0.49, 0.82, 0.76))
    cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
let output = URL(fileURLWithPath: "Embryo/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let image = cg.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot encode icon.") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon.") }
print("Generated \(output.path)")
