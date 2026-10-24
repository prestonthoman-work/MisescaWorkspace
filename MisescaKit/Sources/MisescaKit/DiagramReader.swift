import Foundation
import CoreGraphics
import CoreText
import Vision

/// Finds table outlines and short text in a diagram image, on device.
public enum DiagramReader {
    /// Large photos are scaled down before tracing; table outlines survive and noise drops away.
    static let traceDimension = 2048

    public static func read(_ image: CGImage) throws -> DiagramReading {
        let w = Double(image.width), h = Double(image.height)
        func pixel(_ p: CGPoint) -> PlanPoint { PlanPoint(x: Double(p.x) * w, y: (1 - Double(p.y)) * h) }

        let contours = VNDetectContoursRequest()
        contours.detectsDarkOnLight = true
        contours.contrastAdjustment = 1.5
        contours.maximumImageDimension = traceDimension

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.005

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([contours, text])

        var shapes: [DiagramShape] = []
        if let observation = contours.results?.first {
            for i in 0..<observation.contourCount {
                guard let contour = try? observation.contour(at: i) else { continue }
                // Thin out very dense outlines; the shape tests only need the outline's form.
                let simplified = (try? contour.polygonApproximation(epsilon: 0.0005)) ?? contour
                let points = simplified.normalizedPoints.map { pixel(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))) }
                if let shape = ShapeClassifier.classify(points) { shapes.append(shape) }
            }
        }

        var texts: [DiagramText] = (text.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return DiagramText(text: s, center: pixel(CGPoint(x: box.midX, y: box.midY)))
        }
        texts += readInsideShapes(shapes, of: image)

        return DiagramReading(imageWidth: w, imageHeight: h, shapes: shapes, texts: texts)
    }

    /// Page-wide text reading skips lone numbers, which is what table labels usually are.
    /// Reading each shape on its own, enlarged, picks them up.
    static func readInsideShapes(_ shapes: [DiagramShape], of image: CGImage) -> [DiagramText] {
        let w = Double(image.width), h = Double(image.height)
        let candidates = shapes
            .filter { $0.length >= 16 && $0.length <= min(w, h) / 3 }
            .sorted { $0.length * $0.width > $1.length * $1.width }
        var done: [DiagramShape] = []
        var out: [DiagramText] = []
        for shape in candidates {
            // An outline traces twice; read each spot once.
            if done.contains(where: { $0.center.distance(to: shape.center) < $0.width / 2 }) { continue }
            done.append(shape)

            let half = max(shape.length, shape.width) / 2 * 1.15
            let rect = CGRect(x: shape.center.x - half, y: shape.center.y - half, width: 2 * half, height: 2 * half)
                .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let crop = image.cropping(to: rect), let big = enlarged(crop, toHeight: 240) else { continue }

            if let string = recognize(big, level: .accurate) ?? recognizeSingle(big) {
                out.append(DiagramText(text: string, center: shape.center))
            }
        }
        return out
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

    /// Text recognition skips a lone character such as "7". Set after a known word it reads
    /// as a line, "Table 7", and the word is stripped off again.
    static func recognizeSingle(_ image: CGImage) -> String? {
        let w = Double(image.width), h = Double(image.height)
        // The middle of the shape, clear of its outline, then just the ink inside it.
        let inner = CGRect(x: w * 0.25, y: h * 0.25, width: w * 0.5, height: h * 0.5).integral
        guard let middle = image.cropping(to: inner), let ink = inkBounds(middle),
              let glyph = middle.cropping(to: ink) else { return nil }

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
        guard s.lowercased().hasPrefix("table") else { return nil }
        let rest = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Bounding box of dark pixels, in the image's own top-left pixel coordinates, with a little margin.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[y * w + x] < 110 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY, maxY - minY >= 4 else { return nil }
        // Gray buffer rows run top to bottom, matching CGImage cropping coordinates.
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
