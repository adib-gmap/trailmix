#!/usr/bin/env swift
//
// Generates Trailmix's .iconset from the same ridge mark MenuBarController
// draws in the menu bar, so the two never drift apart.
//
//     swift Scripts/make-icon.swift <output.iconset>
//     iconutil -c icns <output.iconset>
//
// Every size is rendered from the vector directly rather than downscaled from
// one 1024 master. The ridge is a thin silhouette; bicubic-resampling it to
// 16pt softens the peaks into grey haze, which is the same reason the menu bar
// mark is filled rather than stroked.

import AppKit
import Foundation

// The ridge, in the 24x24 viewBox of MenuBarController.iconSVG. Keep these in
// sync with that path if the mark ever changes.
let ridge: [CGPoint] = [
    CGPoint(x: 0.6, y: 19.6),
    CGPoint(x: 8.4, y: 5.4),
    CGPoint(x: 12.7, y: 13.2),
    CGPoint(x: 15.3, y: 9.3),
    CGPoint(x: 23.4, y: 19.6),
]
let ridgeBox = CGRect(x: 0.6, y: 5.4, width: 22.8, height: 14.2)

// Apple's icon grid: the rounded square occupies 824pt of a 1024pt canvas,
// leaving the margin the system expects for shadows and alignment.
let squircleRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 0.2237

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let skyTop = color(0x3F6E9E)      // dusk slate blue
let skyBottom = color(0x152739)   // near-black at the horizon
let ridgeFill = color(0xF4EFE3)   // warm cream, high contrast at 16pt

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }

    let side = CGFloat(size)

    // Flip to a top-left origin so the SVG coordinates below can be used as
    // written, without mentally inverting every y.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)

    let plate = side * squircleRatio
    let inset = (side - plate) / 2
    let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
    let squircle = CGPath(
        roundedRect: plateRect,
        cornerWidth: plate * cornerRatio,
        cornerHeight: plate * cornerRatio,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [skyTop, skyBottom] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plateRect.midX, y: plateRect.minY),
            end: CGPoint(x: plateRect.midX, y: plateRect.maxY),
            options: []
        )
    }

    // Scale the ridge to a fraction of the plate and drop it just below centre;
    // a mountain centred exactly on the optical middle reads as floating.
    let ridgeWidth = plate * 0.68
    let ridgeHeight = ridgeWidth * (ridgeBox.height / ridgeBox.width)
    let originX = (side - ridgeWidth) / 2
    let originY = (side - ridgeHeight) / 2 + plate * 0.045
    let scaleX = ridgeWidth / ridgeBox.width
    let scaleY = ridgeHeight / ridgeBox.height

    func place(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: originX + (point.x - ridgeBox.minX) * scaleX,
            y: originY + (point.y - ridgeBox.minY) * scaleY
        )
    }

    ctx.beginPath()
    ctx.move(to: place(ridge[0]))
    for point in ridge.dropFirst() {
        ctx.addLine(to: place(point))
    }
    ctx.closePath()
    ctx.setFillColor(ridgeFill)
    ctx.fillPath()
    ctx.restoreGState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: -

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: swift Scripts/make-icon.swift <output.iconset>\n".utf8
    ))
    exit(64)
}

let outputPath = CommandLine.arguments[1]
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)

// The iconset names macOS's iconutil expects. 32, 256 and 512 each appear
// twice, at different nominal point sizes; the pixel content is identical.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    // Cache by pixel size so the duplicated dimensions render once.
    var cache: [Int: Data] = [:]
    for variant in variants {
        let png: Data
        if let hit = cache[variant.pixels] {
            png = hit
        } else {
            guard let fresh = render(size: variant.pixels) else {
                FileHandle.standardError.write(Data(
                    "failed to render \(variant.pixels)px\n".utf8
                ))
                exit(1)
            }
            cache[variant.pixels] = fresh
            png = fresh
        }
        try png.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
    }
    print("wrote \(variants.count) images to \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("icon generation failed: \(error)\n".utf8))
    exit(1)
}
