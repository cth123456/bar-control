#!/usr/bin/swift

import AppKit
import Foundation

private let canvas = NSSize(width: 1024, height: 1024)

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func fill(_ path: NSBezierPath, _ value: NSColor) {
    value.setFill()
    path.fill()
}

private func stroke(_ path: NSBezierPath, _ value: NSColor, width: CGFloat) {
    value.setStroke()
    path.lineWidth = width
    path.stroke()
}

private func drawBase(start: UInt32, end: UInt32) {
    let frame = NSRect(x: 44, y: 44, width: 936, height: 936)
    NSGraphicsContext.current?.shouldAntialias = true

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    fill(rounded(frame, radius: 218), color(start))
    NSGraphicsContext.restoreGraphicsState()

    let base = rounded(frame, radius: 218)
    NSGradient(starting: color(start), ending: color(end))?.draw(in: base, angle: -48)
    stroke(base, NSColor.white.withAlphaComponent(0.18), width: 8)

    let sheen = rounded(NSRect(x: 86, y: 548, width: 852, height: 344), radius: 158)
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.20),
        ending: NSColor.white.withAlphaComponent(0.0)
    )?.draw(in: sheen, angle: -90)
}

private func barControlIcon() {
    drawBase(start: 0x111827, end: 0x3158C7)
    let bar = rounded(NSRect(x: 132, y: 326, width: 760, height: 364), radius: 132)
    fill(bar, color(0x080C17, alpha: 0.90))
    stroke(bar, NSColor.white.withAlphaComponent(0.28), width: 10)

    let modules: [(NSRect, UInt32)] = [
        (NSRect(x: 188, y: 414, width: 178, height: 188), 0x22C55E),
        (NSRect(x: 390, y: 414, width: 246, height: 188), 0x3B82F6),
        (NSRect(x: 660, y: 414, width: 80, height: 188), 0xA855F7),
        (NSRect(x: 764, y: 414, width: 72, height: 188), 0xF59E0B),
    ]
    for (rect, tint) in modules {
        let path = rounded(rect, radius: min(rect.height / 2, 62))
        fill(path, color(tint, alpha: 0.92))
        stroke(path, NSColor.white.withAlphaComponent(0.22), width: 5)
    }

    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: 503, y: 472))
    spark.line(to: NSPoint(x: 530, y: 544))
    spark.line(to: NSPoint(x: 558, y: 472))
    spark.lineCapStyle = .round
    stroke(spark, .white, width: 20)
}

private func sidecarIcon() {
    drawBase(start: 0x0F5A68, end: 0x159DE0)

    let mac = rounded(NSRect(x: 138, y: 268, width: 526, height: 412), radius: 58)
    fill(mac, color(0x071925, alpha: 0.80))
    stroke(mac, .white, width: 18)
    let macScreen = rounded(NSRect(x: 178, y: 318, width: 446, height: 312), radius: 30)
    NSGradient(starting: color(0x34D399), ending: color(0x22D3EE))?.draw(in: macScreen, angle: -25)
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 328, y: 246))
    stand.line(to: NSPoint(x: 474, y: 246))
    stand.move(to: NSPoint(x: 400, y: 268))
    stand.line(to: NSPoint(x: 400, y: 246))
    stand.lineCapStyle = .round
    stroke(stand, .white, width: 20)

    let tablet = rounded(NSRect(x: 574, y: 362, width: 284, height: 432), radius: 66)
    fill(tablet, color(0x071925, alpha: 0.90))
    stroke(tablet, .white, width: 18)
    let tabletScreen = rounded(NSRect(x: 610, y: 414, width: 212, height: 326), radius: 36)
    NSGradient(starting: color(0x60A5FA), ending: color(0x8B5CF6))?.draw(in: tabletScreen, angle: -40)

    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: 486, y: 720))
    bridge.curve(
        to: NSPoint(x: 650, y: 796),
        controlPoint1: NSPoint(x: 528, y: 798),
        controlPoint2: NSPoint(x: 596, y: 816)
    )
    bridge.lineCapStyle = .round
    stroke(bridge, NSColor.white.withAlphaComponent(0.92), width: 20)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 619, y: 750))
    arrow.line(to: NSPoint(x: 654, y: 797))
    arrow.line(to: NSPoint(x: 597, y: 812))
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    stroke(arrow, .white, width: 18)
}

private func localModelIcon() {
    drawBase(start: 0x3B176D, end: 0xBD2BD2)

    let core = NSBezierPath(ovalIn: NSRect(x: 350, y: 350, width: 324, height: 324))
    fill(core, color(0x111827, alpha: 0.68))
    stroke(core, NSColor.white.withAlphaComponent(0.92), width: 18)

    let bars: [(CGFloat, CGFloat)] = [
        (238, 152), (306, 236), (374, 322), (650, 322), (718, 236), (786, 152),
    ]
    for (x, height) in bars {
        let rect = NSRect(x: x, y: 512 - height / 2, width: 32, height: height)
        fill(rounded(rect, radius: 16), NSColor.white.withAlphaComponent(0.94))
    }

    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 417, y: 514))
    wave.curve(
        to: NSPoint(x: 607, y: 514),
        controlPoint1: NSPoint(x: 459, y: 654),
        controlPoint2: NSPoint(x: 565, y: 374)
    )
    wave.lineCapStyle = .round
    stroke(wave, .white, width: 25)

    let sparkle = NSBezierPath()
    sparkle.move(to: NSPoint(x: 700, y: 744))
    sparkle.line(to: NSPoint(x: 720, y: 800))
    sparkle.line(to: NSPoint(x: 740, y: 744))
    sparkle.move(to: NSPoint(x: 674, y: 772))
    sparkle.line(to: NSPoint(x: 766, y: 772))
    sparkle.lineCapStyle = .round
    stroke(sparkle, color(0xFDE68A), width: 14)
}

private func render(name: String, draw: () -> Void, outputDirectory: URL) throws {
    let image = NSImage(size: canvas)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvas).fill()
    draw()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

private func renderTemplate(outputDirectory: URL) throws {
    let size = NSSize(width: 36, height: 36)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    let shell = rounded(NSRect(x: 2, y: 7, width: 32, height: 22), radius: 6)
    stroke(shell, .white, width: 2.2)
    for (rect, alpha) in [
        (NSRect(x: 6, y: 12, width: 7, height: 12), CGFloat(1)),
        (NSRect(x: 15, y: 12, width: 11, height: 12), CGFloat(0.82)),
        (NSRect(x: 28, y: 12, width: 3, height: 12), CGFloat(0.66)),
    ] {
        fill(rounded(rect, radius: 1.5), NSColor.white.withAlphaComponent(alpha))
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    try png.write(to: outputDirectory.appendingPathComponent("bar-control-template.png"), options: .atomic)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/assets", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try render(name: "icon-bar-control.png", draw: barControlIcon, outputDirectory: outputDirectory)
try render(name: "icon-sidecar-pilot.png", draw: sidecarIcon, outputDirectory: outputDirectory)
try render(name: "icon-local-model.png", draw: localModelIcon, outputDirectory: outputDirectory)
try renderTemplate(outputDirectory: outputDirectory)
