import AppKit
import ImageIO
import UniformTypeIdentifiers
import ZamazkaKit

/// The document as pages of pixels: one for a picture, one per page for a PDF.
public struct ReprintSource {
    public let pages: [CGImage]
    public let isPDF: Bool

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"]

    public struct Unsupported: Error, LocalizedError { public var errorDescription: String? { "Перепечатать можно картинку или PDF." } }

    public static func canReprint(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "pdf" || imageExtensions.contains(ext)
    }

    public init(data: Data, name: String) throws {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), doc.numberOfPages > 0
            else { throw Unsupported() }
            pages = (1...doc.numberOfPages).compactMap { Self.raster(doc.page(at: $0)!, long: 2400) }
            isPDF = true
        } else {
            guard Self.imageExtensions.contains(ext), let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw Unsupported() }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 4000]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw Unsupported() }
            pages = [img]
            isPDF = false
        }
        if pages.isEmpty { throw Unsupported() }
    }

    init(pages: [CGImage], isPDF: Bool) { self.pages = pages; self.isPDF = isPDF }

    static func raster(_ page: CGPDFPage, long: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let s = long / max(size.width, size.height)
        let w = Int(size.width * s), h = Int(size.height * s)
        let ctx = ReprintRender.context(w, h)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}

/// A field Zamazka found, on one page. Rects are in page pixels, origin top left.
public struct ReprintField: Identifiable, Equatable {
    public let id = UUID()
    public let page: Int
    public let kind: FindingKind
    public let rects: [CGRect]
    public var hidden = false
}

/// Copy layout of spec/issue-code.md («Вёрстка кода на копии»).
public struct ReprintRender {
    public var purpose: String
    public var code: String
    public var date: Date

    public init(purpose: String, code: String, date: Date) {
        self.purpose = purpose; self.code = code; self.date = date
    }

    static let lock = NSLock()

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }

    public var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }

    public var line: String { "Для: \(purpose), \(dateText)" }

    /// Zamazka first, then the pattern and the band on top.
    public func page(_ original: CGImage, hiding rects: [CGRect]) -> CGImage {
        let base = rects.isEmpty ? original : (Redactor.render(original, rects: rects, style: RedactStyle(fill: .solid, color: .ink)) ?? original)
        return render(base)
    }

    func render(_ original: CGImage) -> CGImage {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let w = original.width, docH = original.height
        let k = CGFloat(w) / 1600
        let long = CGFloat(max(w, docH))
        let codeFont = max(54 * k, 0.03 * long)
        let patternFont = max(40 * k, 0.022 * long)
        let bandH = max(Int(CGFloat(docH) * 0.13), Int(codeFont * 1.9))
        let h = docH + bandH
        let ctx = Self.context(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(original, in: CGRect(x: 0, y: bandH, width: w, height: docH))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let ink = NSColor(srgbRed: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0, alpha: 1)
        let s = patternFont / 40
        let pattern = "для: \(purpose), № \(code)" as NSString
        let pAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: patternFont, weight: .semibold),
                                                     .foregroundColor: ink.withAlphaComponent(0.14)]
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: bandH, width: w, height: docH))
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(bandH) + CGFloat(docH) / 2)
        ctx.rotate(by: .pi / 9)
        let span = long
        var row = -span, shift: CGFloat = 0
        while row < span {
            var x = -span * 1.2 + shift
            while x < span * 1.2 {
                pattern.draw(at: NSPoint(x: x, y: row), withAttributes: pAttrs)
                x += 900 * s
            }
            row += 150 * s
            shift = shift == 0 ? 450 * s : 0
        }
        ctx.restoreGState()

        NSColor(srgbRed: 1, green: 0xC2 / 255.0, blue: 0x1A / 255.0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: bandH).fill()
        let mono: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: codeFont, weight: .bold), .foregroundColor: ink]
        let pad = 48 * k
        let codeText = "№ \(code)" as NSString
        let codeSize = codeText.size(withAttributes: mono)
        var mainSize = 54 * k
        let room = CGFloat(w) - 3 * pad - codeSize.width
        let natural = (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: mainSize, weight: .bold)]).width
        if natural > room, room > 0 { mainSize *= room / natural }
        let main: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: mainSize, weight: .bold), .foregroundColor: ink]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: mainSize * 30 / 54, weight: .medium),
                                                    .foregroundColor: ink.withAlphaComponent(0.75)]
        let lineY = CGFloat(bandH) / 2 - 6 * k
        (line as NSString).draw(at: NSPoint(x: pad, y: lineY), withAttributes: main)
        ("Копия. Другим лицам не передаётся." as NSString).draw(at: NSPoint(x: pad, y: lineY - mainSize * 44 / 54), withAttributes: small)
        codeText.draw(at: NSPoint(x: CGFloat(w) - pad - codeSize.width, y: (CGFloat(bandH) - codeSize.height) / 2), withAttributes: mono)
        return ctx.makeImage()!
    }

    /// The finished copy: JPEG for a picture, PDF for a PDF. Nothing of the original's metadata.
    public func copy(_ source: ReprintSource, fields: [ReprintField]) -> (data: Data, ext: String) {
        let pages = source.pages.enumerated().map { i, img in
            page(img, hiding: fields.filter { $0.hidden && $0.page == i }.flatMap(\.rects))
        }
        if source.isPDF { return (Self.pdf(pages), "pdf") }
        return (Self.jpeg(pages[0]), "jpg")
    }

    static func jpeg(_ img: CGImage) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pdf(_ pages: [CGImage]) -> Data {
        let out = NSMutableData()
        var box = CGRect.zero
        let consumer = CGDataConsumer(data: out)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: ""] as CFDictionary)!
        for img in pages {
            // 150 dpi pages: the long side 2400 px is 16 inches, the size of the original page.
            var r = CGRect(x: 0, y: 0, width: CGFloat(img.width) * 72 / 150, height: CGFloat(img.height) * 72 / 150)
            ctx.beginPage(mediaBox: &r)
            ctx.draw(img, in: r)
            ctx.endPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// Fields Zamazka finds on every page.
    public static func fields(_ source: ReprintSource) async -> [ReprintField] {
        var out: [ReprintField] = []
        for (i, img) in source.pages.enumerated() {
            guard let a = try? await Detector.analyze(img, options: DetectorOptions(enabled: Set(FindingKind.detectable))) else { continue }
            out += a.findings.map { ReprintField(page: i, kind: $0.kind, rects: $0.rects) }
        }
        return out
    }
}

/// The mark Desk knows a copy by (spec/reprint.md, «Метка копии»).
public enum ReprintMark {
    public static let name = "com.vldvr.redakciya.reprint"

    public static func write(_ url: URL, code: String, at: Date) {
        let v = Data("\(code) \(ISO8601DateFormatter().string(from: at))".utf8)
        _ = v.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, v.count, 0, 0) }
    }

    /// (code, issued) or nil when there is no readable mark.
    public static func read(_ url: URL) -> (code: String, at: Date)? {
        let n = getxattr(url.path, name, nil, 0, 0, 0)
        guard n > 0, n < 200 else { return nil }
        var d = Data(count: n)
        let got = d.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, n, 0, 0) }
        guard got == n, let s = String(data: d, encoding: .utf8) else { return nil }
        let parts = s.split(separator: " ")
        guard parts.count == 2, let at = ISO8601DateFormatter().date(from: String(parts[1])) else { return nil }
        return (String(parts[0]), at)
    }
}
