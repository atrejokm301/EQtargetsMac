#!/usr/bin/env swift
//
//  make-app-icon.swift — builds the macOS AppIcon.appiconset from the iOS art.
//
//  Usage:
//    swift scripts/make-app-icon.swift \
//        ~/EQtargetsMusic/EQtargetsMusic/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
//        Sources/App/Resources/Assets.xcassets/AppIcon.appiconset
//
//  STOPGAP per docs/DESIGN.md §13. The real fix is a layered Icon Composer
//  `.icon` made by a human. Until then this keeps the brand while fixing the
//  worst problems of reusing the iOS 1024 px art as-is:
//    • "icon inside an icon": the iOS art is a bezelled plate (~61% of the
//      canvas) on a grey canvas with a purple glow. We crop INSIDE the bezel,
//      so the grey canvas, the glow and the metal bezel are gone;
//    • the frequency labels (which say "20" twice) are painted out;
//    • the art sits on the standard macOS grid: an 824 px continuous-corner
//      body on the 1024 canvas, a dark #1A1A22 → #0E0E14 gradient with a soft
//      purple-blue bloom top-centre, and a soft drop shadow.
//  Not done (needs real art): removing the dart's crack lines, thickening the
//  curve for 16/32 px, the Liquid Glass layers.
//

import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <ios-1024.png> <AppIcon.appiconset dir>\n".utf8))
    exit(2)
}
let srcURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

guard let src = NSImage(contentsOf: srcURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      src.width == 1024, src.height == 1024 else {
    FileHandle.standardError.write(Data("expected a 1024×1024 source at \(srcURL.path)\n".utf8))
    exit(1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// MARK: 1. Paint out the frequency labels (source pixel coords, origin top-left).
// Measured from the source: one text row at y 240…263; the dart's flights sit
// between the duplicate "20" and "20k", so every box stops short of them.
let labelBoxes: [(x0: Int, x1: Int)] = [(264, 294), (338, 378), (414, 454), (497, 528), (575, 606), (650, 686), (729, 766)]
let labelY0 = 240, labelY1 = 263

let art = context(1024, 1024)
art.draw(src, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let artData = art.data?.assumingMemoryBound(to: UInt8.self) else { exit(1) }
let rowBytes = art.bytesPerRow
func pixel(_ x: Int, _ yTop: Int) -> (UInt8, UInt8, UInt8) {
    // CGContext memory is top-down for this bitmap layout.
    let p = artData + yTop * rowBytes + x * 4
    return (p[0], p[1], p[2])
}
for box in labelBoxes {
    // Local background: average of the columns just outside the box.
    var r = 0, g = 0, b = 0, n = 0
    for y in labelY0 ... labelY1 {
        for x in [box.x0 - 3, box.x0 - 2, box.x1 + 2, box.x1 + 3] {
            let c = pixel(x, y); r += Int(c.0); g += Int(c.1); b += Int(c.2); n += 1
        }
    }
    art.setFillColor(CGColor(srgbRed: CGFloat(r / n) / 255, green: CGFloat(g / n) / 255, blue: CGFloat(b / n) / 255, alpha: 1))
    art.fill(CGRect(x: box.x0, y: 1024 - labelY1 - 1, width: box.x1 - box.x0, height: labelY1 - labelY0 + 1))
}
guard let cleaned = art.makeImage() else { exit(1) }

// MARK: 2. Crop inside the bezel (inner screen measured at x/y 218…806).
let cropTop = 222, cropSize = 580
guard let screen = cleaned.cropping(to: CGRect(x: 222, y: cropTop, width: cropSize, height: cropSize)) else { exit(1) }

// Feathered rounded-rect mask so the crop edge melts into the background
// instead of showing the screen's own corners. clip(to:mask:) needs a
// DeviceGray image without alpha, so the blurred mask is redrawn into one.
let rounded: CIImage = {
    let m = context(cropSize, cropSize)
    m.setFillColor(.black); m.fill(CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
    m.setFillColor(.white)
    m.addPath(CGPath(roundedRect: CGRect(x: 30, y: 30, width: cropSize - 60, height: cropSize - 60),
                     cornerWidth: 70, cornerHeight: 70, transform: nil))
    m.fillPath()
    return CIImage(cgImage: m.makeImage()!)
}()
let blurred = rounded.clampedToExtent().applyingGaussianBlur(sigma: 14)
    .cropped(to: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
let ci = CIContext(options: [.workingColorSpace: space])
guard let maskRGB = ci.createCGImage(blurred, from: blurred.extent) else { exit(1) }
let grayCtx = CGContext(data: nil, width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
grayCtx.draw(maskRGB, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
guard let mask = grayCtx.makeImage() else { exit(1) }

// MARK: 3. Compose the 1024 master on the macOS grid.
let canvas = context(1024, 1024)
canvas.interpolationQuality = .high
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow under the body.
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
canvas.addPath(bodyPath); canvas.setFillColor(rgb(0x14141A)); canvas.fillPath()
canvas.restoreGState()

canvas.saveGState()
canvas.addPath(bodyPath); canvas.clip()
// Background gradient (top #1A1A22 → bottom #0E0E14) + purple-blue bloom top-centre.
let grad = CGGradient(colorsSpace: space, colors: [rgb(0x1A1A22), rgb(0x0E0E14)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let bloom = CGGradient(colorsSpace: space, colors: [rgb(0x5B5BD6, 0.25), rgb(0x5B5BD6, 0)] as CFArray, locations: [0, 1])!
canvas.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                          endCenter: CGPoint(x: 512, y: 860), endRadius: 520, options: [])
// The art, scaled to fill the body with a small margin, faded at its edges.
let artRect = CGRect(x: 512 - 390, y: 512 - 390, width: 780, height: 780)
canvas.saveGState()
canvas.clip(to: artRect, mask: mask)
canvas.draw(screen, in: artRect)
canvas.restoreGState()
// Hairline inner edge so the body reads on dark Docks too.
canvas.addPath(bodyPath); canvas.setStrokeColor(rgb(0xFFFFFF, 0.10)); canvas.setLineWidth(3); canvas.strokePath()
canvas.restoreGState()

guard let master = canvas.makeImage() else { exit(1) }
let masterURL = outDir.appendingPathComponent("icon_512x512@2x.png")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: master)
try! rep.representation(using: .png, properties: [:])!.write(to: masterURL)

// MARK: 4. Sizes via sips, and Contents.json.
let sizes: [(name: String, px: Int, size: String, scale: String)] = [
    ("icon_16x16.png", 16, "16x16", "1x"), ("icon_16x16@2x.png", 32, "16x16", "2x"),
    ("icon_32x32.png", 32, "32x32", "1x"), ("icon_32x32@2x.png", 64, "32x32", "2x"),
    ("icon_128x128.png", 128, "128x128", "1x"), ("icon_128x128@2x.png", 256, "128x128", "2x"),
    ("icon_256x256.png", 256, "256x256", "1x"), ("icon_256x256@2x.png", 512, "256x256", "2x"),
    ("icon_512x512.png", 512, "512x512", "1x"), ("icon_512x512@2x.png", 1024, "512x512", "2x"),
]
for s in sizes where s.px != 1024 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(s.px)", "\(s.px)", masterURL.path, "--out", outDir.appendingPathComponent(s.name).path]
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { FileHandle.standardError.write(Data("sips failed for \(s.name)\n".utf8)); exit(1) }
}
let images = sizes.map { "    { \"filename\" : \"\($0.name)\", \"idiom\" : \"mac\", \"scale\" : \"\($0.scale)\", \"size\" : \"\($0.size)\" }" }
let json = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("make-app-icon: wrote \(sizes.count) PNGs + Contents.json to \(outDir.path)")
