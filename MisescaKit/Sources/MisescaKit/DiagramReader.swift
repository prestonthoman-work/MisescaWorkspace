import Foundation
import CoreGraphics
import CoreText
import Vision

/// Finds table shapes and text in a diagram image, on device.
public enum DiagramReader {
    public static func read(_ image: CGImage) throws -> DiagramReading {
        DiagramReading(imageWidth: Double(image.width), imageHeight: Double(image.height),
                       shapes: RegionTracer.shapes(in: image), texts: try readText(image))
    }

    /// Longest side of each piece the page is cut into for reading text.
    static let textTile = 1400.0

    /// Text across the whole page, then again piece by piece. The reader shrinks a big page
    /// before reading it, which loses small labels like "Table 7" or "BAR"; a piece keeps them.
    public static func readText(_ image: CGImage) throws -> [DiagramText] {
        let w = Double(image.width), h = Double(image.height)
        var texts = try recognizeAll(image, in: CGRect(x: 0, y: 0, width: w, height: h), full: CGSize(width: w, height: h))
        let n = Int((max(w, h) / textTile).rounded(.up))
        guard n >= 2 else { return texts }
        let tw = w / Double(n), th = h / Double(n)
        // Overlap pieces so a label on a seam is whole in one of them.
        let overlapX = tw * 0.15, overlapY = th * 0.15
        for i in 0..<n {
            for j in 0..<n {
                let r = CGRect(x: max(0, Double(i) * tw - overlapX), y: max(0, Double(j) * th - overlapY),
                               width: min(w, Double(i + 1) * tw + overlapX) - max(0, Double(i) * tw - overlapX),
                               height: min(h, Double(j + 1) * th + overlapY) - max(0, Double(j) * th - overlapY)).integral
                for t in try recognizeAll(image, in: r, full: CGSize(width: w, height: h)) {
                    let key = t.text.lowercased().filter { !$0.isWhitespace }
                    let duplicate = texts.contains {
                        $0.center.distance(to: t.center) < max(w, h) * 0.01 && $0.text.lowercased().filter { !$0.isWhitespace } == key
                    }
                    if !duplicate { texts.append(t) }
                }
            }
        }
        return texts
    }

    /// Confident lines of text inside `rect` of the image, placed in whole-image pixels.
    /// Lines cut by the edge of a piece are left for the piece that holds them whole.
    static func recognizeAll(_ image: CGImage, in rect: CGRect, full: CGSize) throws -> [DiagramText] {
        let isWhole = rect.width >= full.width && rect.height >= full.height
        guard let piece = isWhole ? image : image.cropping(to: rect) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: piece, options: [:]).perform([request])
        let pw = Double(rect.width), ph = Double(rect.height)
        return (request.results ?? []).compactMap { obs in
            // Rows of chairs can look like "oo oo" to a text reader; keep only confident reads.
            guard let top = obs.topCandidates(1).first, top.confidence >= 0.5 else { return nil }
            let box = obs.boundingBox
            if !isWhole {
                let margin = 0.004
                let cutX = (box.minX < margin && rect.minX > 0) || (box.maxX > 1 - margin && rect.maxX < full.width)
                let cutY = (box.minY < margin && rect.maxY < full.height) || (box.maxY > 1 - margin && rect.minY > 0)
                if cutX || cutY { return nil }
            }
            return DiagramText(text: top.string,
                               center: PlanPoint(x: Double(rect.minX) + Double(box.midX) * pw,
                                                 y: Double(rect.minY) + (1 - Double(box.midY)) * ph),
                               width: Double(box.width) * pw, height: Double(box.height) * ph)
        }
    }

    /// Page-wide text reading skips lone numbers, which is what table labels usually are.
    /// Reading each table on its own, enlarged, picks them up.
    /// `page` is the text already read across the page: where it spells out "Table 12" on a
    /// table, that table's label is read as it stands. Tables are read in parallel.
    public static func readLabels(at shapes: [DiagramShape], in image: CGImage, page: [DiagramText] = []) -> [DiagramText] {
        let spelled = page.filter { DiagramLayoutBuilder.tableNumber($0.text) != $0.text.trimmingCharacters(in: .whitespaces) }
        var results = [DiagramText?](repeating: nil, count: shapes.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: shapes.count) { i in
            let shape = shapes[i]
            // Only the inside of the table, turned level, so chairs and neighbors can't be read as a number.
            let inside: (Double, Double) = shape.kind == .circle
                ? (shape.length * 0.7, shape.length * 0.7)
                : (shape.length * 0.92, shape.width * 0.8)
            guard let patch = levelPatch(image, center: shape.center, length: inside.0, width: inside.1,
                                         rotationDegrees: shape.kind == .circle ? 0 : shape.rotationDegrees),
                  let big = enlarged(patch, toHeight: 200) else { return }
            // A label that says "Table 12" or "Gift table" reads as it is: the page spelled it out,
            // or its ink is wider than three digits. Otherwise read after a known word first: a lone
            // "9" on its own has no right way up and can read as "6".
            let box = Footprint(center: shape.center, length: shape.length, width: shape.width, rotationDegrees: shape.rotationDegrees)
            let glyph = labelInk(big)
            let wide = glyph.map { Double($0.width) > Double($0.height) * 2.6 } ?? false
            let string = wide || spelled.contains(where: { box.contains($0.center) })
                ? recognize(big, level: .accurate) ?? glyph.flatMap(recognizeSingle(glyph:))
                : glyph.flatMap(recognizeSingle(glyph:)) ?? recognize(big, level: .accurate)
            guard let string else { return }
            lock.lock()
            results[i] = DiagramText(text: string, center: shape.center)
            lock.unlock()
        }
        return results.compactMap { $0 }
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
        labelInk(image).flatMap(recognizeSingle(glyph:))
    }

    /// Just the label's ink from a table patch, dark on white.
    static func labelInk(_ image: CGImage) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        // Trim the patch edge, then keep just the label's ink.
        let inner = CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.8).integral
        guard var middle = image.cropping(to: inner) else { return nil }
        // White numbers on a filled table: flip to dark on light. Either way, stretch so the
        // table top is white; a gray box around the pasted number confuses the reader.
        if meanBrightness(middle) < 110, let flipped = inverted(middle) { middle = flipped }
        if let clean = whitened(middle) { middle = clean }
        guard let ink = inkBounds(middle) else { return nil }
        return middle.cropping(to: ink)
    }

    static func recognizeSingle(glyph: CGImage) -> String? {

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
        guard DiagramLayoutBuilder.isTableWord(letters.lowercased()) else { return nil }
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
