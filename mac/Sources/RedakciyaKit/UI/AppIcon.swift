import AppKit

/// The app icon: a cold grey newspaper sheet on an ink tile, one line of text under the marker.
/// Drawn in code; scripts/build-app.sh turns it into AppIcon.icns via `Redakciya --icon-png`.
public enum AppIcon {
    static var image: NSImage { NSImage(cgImage: draw(side: 1024), size: NSSize(width: 1024, height: 1024)) }

    public static func draw(side: Int) -> CGImage {
        let s = CGFloat(side) / 1024
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)

        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
            CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        // Tile: ink, as the main button.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.30))
        ctx.addPath(rounded(tile, 186))
        ctx.setFillColor(color(0x16181B))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded(tile, 186))
        ctx.clip()
        let bg = CGGradient(colorsSpace: space, colors: [color(0x2A2D31), color(0x16181B)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()

        // The sheet: newspaper paper, no rounding to speak of (paper is paper).
        let sheet = CGRect(x: 236, y: 196, width: 552, height: 632)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
        ctx.addPath(rounded(sheet, 14))
        ctx.setFillColor(color(0xEDECE7))
        ctx.fillPath()
        ctx.restoreGState()

        // Masthead and a rule under it.
        ctx.addPath(rounded(CGRect(x: 296, y: 700, width: 432, height: 64), 8))
        ctx.setFillColor(color(0x16181B))
        ctx.fillPath()
        ctx.setFillColor(color(0x16181B))
        ctx.fill(CGRect(x: 296, y: 668, width: 432, height: 8))

        // Text lines; the third one under the marker.
        let lines: [(y: CGFloat, w: CGFloat)] = [(610, 432), (548, 380), (486, 432), (424, 300), (362, 410), (300, 250)]
        let marked = 2
        for (i, l) in lines.enumerated() {
            if i == marked {
                ctx.addPath(rounded(CGRect(x: 280, y: l.y - 30, width: l.w + 32, height: 60), 10))
                ctx.setFillColor(color(0xFFC21A))
                ctx.fillPath()
            }
            ctx.addPath(rounded(CGRect(x: 296, y: l.y - 11, width: l.w, height: 22), 11))
            ctx.setFillColor(i == marked ? color(0x16181B) : color(0x9C9EA2))
            ctx.fillPath()
        }
        return ctx.makeImage()!
    }

    static func writePNG(_ path: String, side: Int = 1024) throws {
        let rep = NSBitmapImageRep(cgImage: draw(side: side))
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
