#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the newmail app-icon master PNG (1024×1024).
//
// Design: a rounded squircle tile with an indigo→cyan diagonal gradient, a clean
// white envelope whose flap forms a crisp V, and a coral "unread" dot in the
// upper-right — a friendly, modern take on a mail mark.
//
// Usage: swift Tools/GenerateAppIcon.swift <output.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// Tile (rounded rect with a small margin).
let margin: CGFloat = 96
let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let corner = tile.width * 0.2237
let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0, 0, 0, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(color(1, 1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// Gradient background.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0.36, 0.40, 1.0), color(0.0, 0.78, 1.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    grad,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)
ctx.restoreGState()

// Envelope body.
let ew = tile.width * 0.58
let eh = ew * 0.66
let env = CGRect(x: tile.midX - ew / 2, y: tile.midY - eh / 2, width: ew, height: eh)
let envCorner = ew * 0.07

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0, 0, 0, 0.18))
ctx.setFillColor(color(1, 1, 1, 1))
ctx.addPath(CGPath(roundedRect: env, cornerWidth: envCorner, cornerHeight: envCorner, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// Envelope flap — a clean V from the top corners to just below center.
ctx.setStrokeColor(color(0.30, 0.36, 0.95))
ctx.setLineWidth(ew * 0.05)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
let inset = envCorner * 0.7
ctx.move(to: CGPoint(x: env.minX + inset, y: env.maxY - inset))
ctx.addLine(to: CGPoint(x: env.midX, y: env.midY + eh * 0.04))
ctx.addLine(to: CGPoint(x: env.maxX - inset, y: env.maxY - inset))
ctx.strokePath()

// Coral "unread" dot, with a white ring to separate it from the envelope.
let dotR = tile.width * 0.10
let dotCenter = CGPoint(x: env.maxX - dotR * 0.2, y: env.maxY + dotR * 0.2)
ctx.setFillColor(color(1, 1, 1, 1))
ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR * 1.18, y: dotCenter.y - dotR * 1.18,
                           width: dotR * 2.36, height: dotR * 2.36))
ctx.setFillColor(color(1.0, 0.42, 0.30))
ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR,
                           width: dotR * 2, height: dotR * 2))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
