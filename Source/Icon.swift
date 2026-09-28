import AppKit

/// Renders the app's original vector artwork at each native icon resolution.
@MainActor @main struct IconRenderer {
    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    static func draw() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 216, yRadius: 216)
        NSGradient(starting: color(15, 24, 47), ending: color(42, 54, 98))!.draw(in: tile, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let glow = NSBezierPath(ovalIn: NSRect(x: 480, y: 610, width: 650, height: 650))
        color(77, 91, 160).withAlphaComponent(0.22).setFill(); glow.fill()
        NSGraphicsContext.restoreGraphicsState()

        // A softly lit tunnel; the green route passes around its outer edge.
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 350, y: 660))
        shield.curve(to: NSPoint(x: 700, y: 660), controlPoint1: NSPoint(x: 455, y: 705), controlPoint2: NSPoint(x: 585, y: 705))
        shield.line(to: NSPoint(x: 700, y: 480))
        shield.curve(to: NSPoint(x: 525, y: 290), controlPoint1: NSPoint(x: 700, y: 375), controlPoint2: NSPoint(x: 600, y: 320))
        shield.curve(to: NSPoint(x: 350, y: 480), controlPoint1: NSPoint(x: 450, y: 320), controlPoint2: NSPoint(x: 350, y: 375))
        shield.close()
        NSGradient(starting: color(89, 91, 206), ending: color(153, 161, 255))!.draw(in: shield, angle: 90)
        color(194, 207, 255).withAlphaComponent(0.4).setStroke()
        shield.lineWidth = 8; shield.stroke()

        let arch = NSBezierPath()
        arch.move(to: NSPoint(x: 445, y: 440))
        arch.line(to: NSPoint(x: 445, y: 510))
        arch.curve(to: NSPoint(x: 605, y: 510), controlPoint1: NSPoint(x: 445, y: 630), controlPoint2: NSPoint(x: 605, y: 630))
        arch.line(to: NSPoint(x: 605, y: 440))
        color(35, 44, 93).setStroke(); arch.lineWidth = 42; arch.lineCapStyle = .round; arch.stroke()

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 258, y: 252))
        path.curve(to: NSPoint(x: 228, y: 674), controlPoint1: NSPoint(x: 175, y: 375), controlPoint2: NSPoint(x: 170, y: 545))
        path.curve(to: NSPoint(x: 719, y: 773), controlPoint1: NSPoint(x: 300, y: 850), controlPoint2: NSPoint(x: 555, y: 850))
        color(11, 25, 43).withAlphaComponent(0.45).setStroke(); path.lineWidth = 92; path.lineCapStyle = .round; path.stroke()
        color(111, 249, 213).setStroke(); path.lineWidth = 58; path.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 692, y: 883))
        arrow.line(to: NSPoint(x: 823, y: 716))
        arrow.line(to: NSPoint(x: 615, y: 731))
        arrow.line(to: NSPoint(x: 683, y: 785))
        arrow.close()
        NSGradient(starting: color(90, 233, 203), ending: color(212, 255, 236))!.draw(in: arrow, angle: 65)

        let dot = NSBezierPath(ovalIn: NSRect(x: 213, y: 207, width: 90, height: 90))
        color(255, 204, 112).setFill(); dot.fill()
        let shine = NSBezierPath(ovalIn: NSRect(x: 230, y: 252, width: 24, height: 17))
        NSColor.white.withAlphaComponent(0.65).setFill(); shine.fill()
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
                draw()
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
