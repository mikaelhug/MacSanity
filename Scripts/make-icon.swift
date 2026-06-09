#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns — a simple, fitting icon: a white
// "computermouse" glyph on a rounded-rect indigo→blue gradient. Run once:
//   swift Scripts/make-icon.swift
//
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Draw the icon at a given pixel size into a PNG.
func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Rounded-rect background with a small transparent margin (macOS icon style).
    let margin = size * 0.06
    let rect = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rect.width * 0.2237
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.34, green: 0.42, blue: 0.96, alpha: 1),
        ending:   NSColor(srgbRed: 0.16, green: 0.20, blue: 0.55, alpha: 1))!
    gradient.draw(in: bg, angle: -90)

    // White glyph, centered, tinted from the (template) SF Symbol.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        let tinted = NSImage(size: s)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
        tinted.draw(at: origin, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    }

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

// iconset entries: (base size, scale-suffix)
let entries: [(Int, String)] = [
    (16, ""), (16, "@2x"), (32, ""), (32, "@2x"),
    (128, ""), (128, "@2x"), (256, ""), (256, "@2x"),
    (512, ""), (512, "@2x"),
]
for (base, suffix) in entries {
    let px = suffix == "@2x" ? base * 2 : base
    let data = render(px)
    let name = "icon_\(base)x\(base)\(suffix).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

// Compile to .icns
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed (\(task.terminationStatus))")
