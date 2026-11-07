import AppKit

/// Three bars for the three agents, and the tallest one looking back at the
/// others. One drawing for the menu bar and the app icon, on an 18pt grid whose
/// edges land on whole pixels at 2x, so the small size stays sharp.
public enum AppMark {
    private static let grid: CGFloat = 18
    private static let ink = NSColor(srgbRed: 0.09, green: 0.094, blue: 0.11, alpha: 1)
    private static let lime = NSColor(srgbRed: 0.784, green: 0.941, blue: 0.192, alpha: 1)

    private static func bars() -> NSBezierPath {
        let path = NSBezierPath()
        path.appendRoundedRect(NSRect(x: 0.5, y: 2, width: 4, height: 4.5), xRadius: 1.5, yRadius: 1.5)
        path.appendRoundedRect(NSRect(x: 6, y: 2, width: 4, height: 8.5), xRadius: 1.5, yRadius: 1.5)
        path.appendRoundedRect(NSRect(x: 11.5, y: 2, width: 6, height: 14.5), xRadius: 2.5, yRadius: 2.5)
        return path
    }

    private static func eyes(radius: CGFloat, offset: CGPoint = .zero) -> NSBezierPath {
        let path = NSBezierPath()
        for x in [13.15, 15.85] {
            path.appendOval(in: NSRect(x: x + offset.x - radius, y: 13 + offset.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        return path
    }

    /// Black and clear, for the system to tint for the menu bar it sits on.
    public static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: grid, height: grid), flipped: false) { _ in
            let mark = bars()
            mark.append(eyes(radius: 1.1))
            mark.windingRule = .evenOdd
            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The tile on the 824 of 1024 that macOS icons fill, at `pixels` square.
    public static func appIconPNG(pixels: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let size = CGFloat(pixels)
        let tile = NSRect(x: size * 100 / 1024, y: size * 100 / 1024, width: size * 824 / 1024, height: size * 824 / 1024)
        ink.setFill()
        NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()

        let scale = tile.width * 0.72 / grid
        let transform = NSAffineTransform()
        transform.translateX(by: tile.midX - grid / 2 * scale, yBy: tile.midY - 9.25 * scale)
        transform.scale(by: scale)
        transform.concat()
        lime.setFill()
        bars().fill()
        NSColor.white.setFill()
        eyes(radius: 1.2).fill()
        ink.setFill()
        eyes(radius: 0.6, offset: CGPoint(x: -0.4, y: -0.4)).fill()
        return bitmap.representation(using: .png, properties: [:])
    }
}
