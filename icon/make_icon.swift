// Draws the fixmon mascot (a little monitor creature with a bandaged, broken left edge) as a 1024px PNG.
// Usage: swift icon/make_icon.swift out.png   (build.sh turns it into AppIcon.icns)

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

func fillStroke(_ p: NSBezierPath, _ fill: NSColor, _ stroke: NSColor? = nil, _ width: CGFloat = 0) {
    fill.setFill(); p.fill()
    if let stroke { stroke.setStroke(); p.lineWidth = width; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke() }
}

let ink = color(0x2B2140)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon tile: 824pt squircle-ish rounded rect with a sky gradient.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = rounded(tile, 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.3); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x6FD3F7).setFill(); tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: color(0x8BE3FF), ending: color(0x3E8EF0))!.draw(in: tile, angle: -90)
    // soft ground shadow under the creature
    color(0x1D4FA8, 0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: 260, y: 168, width: 504, height: 70)).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Cable tail curling out to the right, ending in a plug.
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 760, y: 300))
    tail.curve(to: NSPoint(x: 860, y: 300), controlPoint1: NSPoint(x: 800, y: 240), controlPoint2: NSPoint(x: 860, y: 240))
    tail.curve(to: NSPoint(x: 850, y: 400), controlPoint1: NSPoint(x: 860, y: 340), controlPoint2: NSPoint(x: 840, y: 360))
    ink.setStroke(); tail.lineWidth = 30; tail.lineCapStyle = .round; tail.stroke()
    color(0xFFB938).setStroke(); tail.lineWidth = 16; tail.stroke()
    let plug = rounded(NSRect(x: 822, y: 392, width: 58, height: 52), 12)
    fillStroke(plug, color(0xFFB938), ink, 14)
    for x in [836.0, 856.0] { fillStroke(rounded(NSRect(x: x, y: 442, width: 10, height: 30), 4), color(0xC9CED8), ink, 8) }

    // Feet
    for x in [330.0, 590.0] { fillStroke(NSBezierPath(ovalIn: NSRect(x: x, y: 190, width: 110, height: 70)), color(0xF29A1F), ink, 16) }

    // Antennas (TV rabbit ears) with glowing bulbs.
    for (base, tip) in [(NSPoint(x: 450, y: 720), NSPoint(x: 330, y: 860)), (NSPoint(x: 574, y: 720), NSPoint(x: 700, y: 870))] {
        let stalk = NSBezierPath()
        stalk.move(to: base); stalk.line(to: tip)
        stalk.lineCapStyle = .round
        ink.setStroke(); stalk.lineWidth = 30; stalk.stroke()
        color(0xC9CED8).setStroke(); stalk.lineWidth = 14; stalk.stroke()
        fillStroke(NSBezierPath(ovalIn: NSRect(x: tip.x - 38, y: tip.y - 38, width: 76, height: 76)), color(0xFF6B6B), ink, 14)
        color(0xFFFFFF, 0.7).setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 18, y: tip.y + 2, width: 20, height: 20)).fill()
    }
    // antenna hub on top of the body
    fillStroke(rounded(NSRect(x: 452, y: 700, width: 120, height: 60), 30), color(0xF29A1F), ink, 16)

    // Body: chunky rounded monitor.
    let body = NSRect(x: 230, y: 230, width: 564, height: 500)
    fillStroke(rounded(body, 120), color(0xFFC94A), ink, 18)
    // belly highlight
    color(0xFFFFFF, 0.25).setFill()
    rounded(NSRect(x: 270, y: 640, width: 300, height: 50), 25).fill()

    // Screen
    let screen = NSRect(x: 290, y: 330, width: 444, height: 320)
    let screenPath = rounded(screen, 60)
    fillStroke(screenPath, color(0x1E2A4A), ink, 14)
    NSGraphicsContext.saveGraphicsState()
    screenPath.addClip()
    NSGradient(starting: color(0x2C3E6E), ending: color(0x16203A))!.draw(in: screen, angle: -90)
    // the broken left strip: pure black with cracks
    color(0x000000).setFill()
    NSRect(x: screen.minX, y: screen.minY, width: 110, height: screen.height).fill()
    let crack = NSBezierPath()
    crack.move(to: NSPoint(x: 400, y: 650)); crack.line(to: NSPoint(x: 360, y: 560)); crack.line(to: NSPoint(x: 395, y: 500))
    crack.line(to: NSPoint(x: 340, y: 420)); crack.line(to: NSPoint(x: 370, y: 330))
    crack.move(to: NSPoint(x: 360, y: 560)); crack.line(to: NSPoint(x: 300, y: 590))
    crack.move(to: NSPoint(x: 395, y: 500)); crack.line(to: NSPoint(x: 430, y: 470))
    color(0x8FA6D8, 0.8).setStroke(); crack.lineWidth = 6; crack.lineJoinStyle = .round; crack.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Face on the working part of the screen.
    for x in [490.0, 620.0] {
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 470, width: 70, height: 96)).fill()
        color(0x1E2A4A).setFill()
        NSBezierPath(ovalIn: NSRect(x: x + 14, y: 480, width: 46, height: 62)).fill()
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: NSRect(x: x + 34, y: 516, width: 18, height: 18)).fill()
    }
    color(0xFF7A9C, 0.85).setFill()
    for x in [455.0, 690.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 420, width: 50, height: 30)).fill() }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 545, y: 425))
    smile.curve(to: NSPoint(x: 625, y: 425), controlPoint1: NSPoint(x: 560, y: 385), controlPoint2: NSPoint(x: 610, y: 385))
    color(0xFFFFFF).setStroke(); smile.lineWidth = 12; smile.lineCapStyle = .round; smile.stroke()

    // Bandage across the broken corner.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 360, yBy: 600); t.rotate(byDegrees: -35)
    t.concat()
    let band = rounded(NSRect(x: -120, y: -32, width: 240, height: 64), 32)
    fillStroke(band, color(0xF6D2B0), ink, 12)
    fillStroke(rounded(NSRect(x: -40, y: -24, width: 80, height: 48), 10), color(0xE8B48C))
    color(0xC98E66).setFill()
    for dx in [-20.0, 0.0, 20.0] { for dy in [-10.0, 10.0] { NSBezierPath(ovalIn: NSRect(x: dx - 4, y: dy - 4, width: 8, height: 8)).fill() } }
    NSGraphicsContext.restoreGraphicsState()

    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
