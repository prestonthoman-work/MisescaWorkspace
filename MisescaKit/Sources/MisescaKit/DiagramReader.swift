import Foundation
import CoreGraphics
import CoreText
import Vision

/// Finds table shapes and text in a diagram image, on device.
public enum DiagramReader {
    public static func read(_ image: CGImage) throws -> DiagramReading {
        let w = Double(image.width), h = Double(image.height)
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text])

        let texts: [DiagramText] = (text.results ?? []).compactMap { obs in
            // Rows of chairs can look like "oo oo" to a text reader; keep only confident reads.
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.5 else { return nil }
            let s = top.string
            let box = obs.boundingBox
            return DiagramText(text: s, center: PlanPoint(x: Double(box.midX) * w, y: (1 - Double(box.midY)) * h))
        }
        return DiagramReading(imageWidth: w, imageHeight: h, shapes: RegionTracer.shapes(in: image), texts: texts)
    }

    /// Page-wide text reading skips lone numbers, which is what table labels usually are.
    /// Reading each table on its own, enlarged, picks them up.
    public static func readLabels(at shapes: [DiagramShape], in image: CGImage) -> [DiagramText] {
        var out: [DiagramText] = []
        for shape in shapes {
            // Only the inside of the table, turned level, so chairs and neighbors can't be read as a number.
            let inside: (Double, Double) = shape.kind == .circle
                ? (shape.length * 0.7, shape.length * 0.7)
                : (shape.length * 0.92, shape.width * 0.8)
            guard let patch = levelPatch(image, center: shape.center, length: inside.0, width: inside.1,
                                         rotationDegrees: shape.kind == .circle ? 0 : shape.rotationDegrees),
                  let big = enlarged(patch, toHeight: 200) else { continue }
            // Read after a known word first: a lone "9" on its own has no right way up and can read as "6".
            if let string = recognizeSingle(big) ?? recognize(big, level: .accurate) {
                out.append(DiagramText(text: string, center: shape.center))
            }
        }
        return out
    }

    /// Cuts out an oriented rectangle of the image and turns it level. Text on a table turned
    /// past 90 degrees would read upside down, so those are turned the other way.
    static func levelPatch(_ image: CGImage, center: PlanPoint, length: Double, width: Double, rotationDegrees: Double) -> CGImage? {
        var angle = rotationDegrees
        if angle > 90 { angle -= 180 }
        let w = max(4, Int(length.rounded())), h = max(4, Int(width.rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        // Work in top-left image coordinates: flip, then rotate about the patch center.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(-angle * .pi / 180))
        ctx.translateBy(x: CGFloat(-center.x), y: CGFloat(-center.y))
        // Draw the image upright in top-left coordinates.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The tallest line of text in an image, if any.
    static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let best = (request.results ?? []).max(by: { $0.boundingBox.height < $1.boundingBox.height }),
              let string = best.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
              string.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return string
    }

    /// Text recognition skips a lone character such as "7" and can't tell "6" from an upside-down "9".
    /// Set after a known word it reads as a line, "Table 7", and the word is stripped off again.
    static func recognizeSingle(_ image: CGImage) -> String? {
        let w = Double(image.width), h = Double(image.height)
        // Trim the patch edge, then keep just the label's ink.
        let inner = CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.8).integral
        guard var middle = image.cropping(to: inner) else { return nil }
        // White numbers on a filled table: flip to dark on light. Either way, stretch so the
        // table top is white; a gray box around the pasted number confuses the reader.
        if meanBrightness(middle) < 110, let flipped = inverted(middle) { middle = flipped }
        if let clean = whitened(middle) { middle = clean }
        guard let ink = inkBounds(middle), let glyph = middle.cropping(to: ink) else { return nil }

        let capHeight = 60.0
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, capHeight / 0.72, nil)
        let word = NSAttributedString(string: "Table", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(word)
        let wordWidth = Double(CTLineGetBoundsWithOptions(line, []).width)
        let glyphWidth = Double(glyph.width) * capHeight / Double(glyph.height)
        let pad = capHeight * 0.6
        let width = Int(pad + wordWidth + capHeight * 0.35 + glyphWidth + pad)
        let height = Int(capHeight * 2.2)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let baseline = (Double(height) - capHeight) / 2
        ctx.textPosition = CGPoint(x: pad, y: baseline)
        CTLineDraw(line, ctx)
        ctx.interpolationQuality = .high
        ctx.draw(glyph, in: CGRect(x: pad + wordWidth + capHeight * 0.35, y: baseline, width: glyphWidth, height: capHeight))

        guard let composed = ctx.makeImage(), let s = recognize(composed, level: .accurate) else { return nil }
        return strippingPrefixWord(s)
    }

    /// "Table 7", "Tabie 7" or "Table7" gives "7". Nil when the known word didn't come back.
    static func strippingPrefixWord(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let letters = trimmed.prefix { $0.isLetter }
        guard letters.count >= 4, letters.count <= 6 else { return nil }
        let word = letters.lowercased()
        let target = Array("table")
        // Close enough to "table": at most one letter different, added or missing.
        var prev = Array(0...target.count)
        for (i, ch) in word.enumerated() {
            var cur = [i + 1]
            for (j, t) in target.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ch == t ? 0 : 1)))
            }
            prev = cur
        }
        guard prev[target.count] <= 1 else { return nil }
        let rest = trimmed.dropFirst(letters.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Stretches brightness so the most common light tone becomes white and the darkest black.
    static func whitened(_ image: CGImage) -> CGImage? {
        guard var p = grayPixels(image), !p.isEmpty else { return nil }
        let sorted = p.sorted()
        let dark = Double(sorted[sorted.count / 100]), light = Double(sorted[sorted.count / 2])
        guard light - dark > 30 else { return nil }
        for i in p.indices {
            p[i] = UInt8(max(0, min(255, (Double(p[i]) - dark) / (light - dark) * 255)))
        }
        let w = image.width, h = image.height
        return p.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    static func grayPixels(_ image: CGImage) -> [UInt8]? {
        RegionTracer.Gray(image)?.pixels
    }

    static func meanBrightness(_ image: CGImage) -> Double {
        guard let p = grayPixels(image), !p.isEmpty else { return 255 }
        return Double(p.reduce(0) { $0 + Int($1) }) / Double(p.count)
    }

    static func inverted(_ image: CGImage) -> CGImage? {
        guard var p = grayPixels(image) else { return nil }
        for i in p.indices { p[i] = 255 - p[i] }
        let w = image.width, h = image.height
        return p.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    /// Bounding box of dark pixels, in the image's own top-left pixel coordinates, with a little margin.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        guard let pixels = grayPixels(image) else { return nil }
        let w = image.width, h = image.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] < 110 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, maxY - minY >= 4 else { return nil }
        let m = 2
        return CGRect(x: max(0, minX - m), y: max(0, minY - m),
                      width: min(w, maxX + m + 1) - max(0, minX - m), height: min(h, maxY + m + 1) - max(0, minY - m))
    }

    static func enlarged(_ image: CGImage, toHeight target: Int) -> CGImage? {
        let scale = max(1, Double(target) / Double(image.height))
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
