import Foundation
import CoreGraphics
import CoreImage

/// How the person ties the diagram to the real room.
public struct DiagramSetup: Hashable, Sendable {
    public enum Scale: Hashable, Sendable {
        /// The house round's real diameter, in feet. Works on diagrams with no dimensions.
        case roundDiameter(Double)
        /// The real room, wall to wall, when the corners are the room's corners.
        case roomSize(widthFt: Double, depthFt: Double)
    }

    /// Corners of the diagram area in the source image, in pixels: top-left, top-right,
    /// bottom-right, bottom-left. For a photo of a printout, the corners of the room or the page.
    public var corners: [PlanPoint]
    public var scale: Scale
    /// Tighten the corners onto the drawn walls or page edges before straightening.
    public var refineCorners: Bool

    public init(corners: [PlanPoint], scale: Scale, refineCorners: Bool = true) {
        self.corners = corners
        self.scale = scale
        self.refineCorners = refineCorners
    }
}

public struct DiagramResult: Sendable {
    /// The diagram straightened and cropped to the corners. Plan coordinates map onto it directly.
    public var image: CGImage
    public var calibration: DiagramCalibration
    public var items: [LayoutItem]
    /// The corners actually used, after tightening, in the source image.
    public var corners: [PlanPoint]
    /// Reasons to double-check this import, worded for the person doing it.
    public var warnings: [String]
    /// Tables whose numbers couldn't be read and were filled in.
    public var guessedLabels: Set<String>
}

public enum DiagramError: Error, Equatable, LocalizedError {
    case badCorners
    case noRoundsToSizeFrom
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .badCorners: return "The corners cross or are too close together. Drag each one to a corner of the diagram."
        case .noRoundsToSizeFrom: return "There aren't at least three matching round tables to size from. Enter the room's width and depth instead."
        case .unreadable: return "Couldn't read this image."
        }
    }
}

public enum DiagramPipeline {
    /// Longest side of the straightened image. Enough for table numbers, small enough to stay quick.
    /// Smaller images aren't enlarged: resampling blurs edges and adds no detail.
    static let maxDimension = 2600.0
    /// Same-size rounds measuring more than this far apart means a blurry or faint image.
    public static let spreadLimit = 0.0032

    public static func run(_ source: CGImage, setup: DiagramSetup) throws -> DiagramResult {
        guard setup.corners.count == 4, isConvex(setup.corners) else { throw DiagramError.badCorners }
        var q = setup.refineCorners ? DiagramCorners.refine(setup.corners, in: source) : setup.corners
        if !isConvex(q) { q = setup.corners }
        let top = q[0].distance(to: q[1]), bottom = q[3].distance(to: q[2])
        let left = q[0].distance(to: q[3]), right = q[1].distance(to: q[2])
        guard min(top, bottom, left, right) > 20 else { throw DiagramError.badCorners }

        // Starting proportions: exact when the room's size is known, otherwise as seen.
        var aspect: Double // height / width
        switch setup.scale {
        case .roomSize(let w, let d): aspect = d / w
        case .roundDiameter: aspect = max(left, right) / max(top, bottom)
        }

        var width = max(top, bottom)
        var image: CGImage
        var reading: DiagramReading
        var pass = 0
        repeat {
            let size = outputSize(width: width, aspect: aspect)
            width = Double(size.width)
            guard let img = rectify(source, corners: q, width: size.width, height: size.height) else { throw DiagramError.unreadable }
            image = img
            // A quick look while straightening; the full search and text are done once, on the final image.
            reading = DiagramReading(imageWidth: Double(img.width), imageHeight: Double(img.height),
                                     shapes: RegionTracer.quickShapes(in: img), texts: [])
            pass += 1
            // A photo's true proportions aren't in the photo. Round tables are round, so if they
            // came out oval, stretch the height until they don't, then read again.
            guard case .roundDiameter = setup.scale, pass < 4,
                  let stretch = DiagramScale.typicalRound(in: reading.shapes)?.stretch,
                  abs(stretch - 1) > 0.003 else { break }
            aspect *= stretch
        } while true

        guard let scan = RegionTracer.Scan(image) else { throw DiagramError.unreadable }
        reading.shapes = RegionTracer.shapes(in: scan)
        reading.texts = try DiagramReader.readText(image)
        // Tables cut up by their own labels. Only real labels: chairs read as "UU" sit on a table's edge.
        let underText = RegionTracer.shapes(in: scan, under: reading.texts.filter { DiagramLayoutBuilder.isLabelOrName($0.text) })
        reading.shapes += underText.filter { s in !reading.shapes.contains { RegionTracer.sameObject($0, s) } }

        let feetPerPixel: Double
        switch setup.scale {
        case .roomSize(let w, _):
            feetPerPixel = w / Double(image.width)
        case .roundDiameter(let d):
            guard let px = DiagramScale.typicalRound(in: reading.shapes)?.diameter else { throw DiagramError.noRoundsToSizeFrom }
            feetPerPixel = d / px
        }
        let calibration = DiagramCalibration(topLeft: PlanPoint(x: 0, y: 0),
                                             bottomRight: PlanPoint(x: Double(image.width), y: Double(image.height)),
                                             feetPerPixel: feetPerPixel)

        // Read numbers only on what may turn out to be tables, including small ones that
        // only count as tables if they carry a number or name.
        let first = DiagramLayoutBuilder.items(from: reading, calibration: calibration, includeUnlabeledSmall: true)
        let tableShapes = first.filter(\.type.isTable).map { item -> DiagramShape in
            let s = item.size
            return DiagramShape(kind: item.type == .roundTable ? .circle : .rectangle, center: calibration.pixel(item.center),
                                length: s.length / feetPerPixel, width: s.width / feetPerPixel, rotationDegrees: item.rotationDegrees)
        }
        reading.texts += DiagramReader.readLabels(at: tableShapes, in: image, page: reading.texts)
        let (items, guessed) = DiagramLayoutBuilder.itemsAndGuesses(from: reading, calibration: calibration)

        var warnings: [String] = []
        let room = calibration.room
        if max(room.widthFt, room.depthFt) > 400 || min(room.widthFt, room.depthFt) < 10 {
            warnings.append("The room works out to \(Int(room.widthFt.rounded())) by \(Int(room.depthFt.rounded())) ft, which doesn't look right. Check the table size, or enter the room's width and depth instead.")
        }
        if case .roundDiameter = setup.scale, let spread = DiagramScale.typicalRound(in: reading.shapes)?.spread, spread > spreadLimit {
            warnings.append("This image is hard to measure precisely, so tables may be up to a foot off. For the best result, use a sharper image or enter the room's width and depth.")
        }
        let missing = DiagramLayoutBuilder.namedWithoutOutline(reading.texts, items: items, calibration: calibration)
        if !missing.isEmpty {
            let list = missing.prefix(6).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            warnings.append("The diagram names \(list), but no outline was found for \(missing.count == 1 ? "it" : "them"). Add \(missing.count == 1 ? "it" : "them") at review if missing.")
        }
        return DiagramResult(image: image, calibration: calibration, items: items, corners: q, warnings: warnings, guessedLabels: guessed)
    }

    static func outputSize(width: Double, aspect: Double) -> (width: Int, height: Int) {
        var w = width, h = width * aspect
        let longest = max(w, h)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        w *= scale
        h *= scale
        return (Int(w.rounded()), Int(h.rounded()))
    }

    static func isConvex(_ q: [PlanPoint]) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    /// Maps the four corners onto a width-by-height rectangle (a true perspective correction,
    /// so a page photographed at an angle comes out flat), on a white background.
    public static func rectify(_ source: CGImage, corners q: [PlanPoint], width: Int, height: Int) -> CGImage? {
        let h = Double(source.height)
        func ci(_ p: PlanPoint) -> CIVector { CIVector(x: p.x, y: h - p.y) }
        let input = CIImage(cgImage: source)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(ci(q[0]), forKey: "inputTopLeft")
        filter.setValue(ci(q[1]), forKey: "inputTopRight")
        filter.setValue(ci(q[2]), forKey: "inputBottomRight")
        filter.setValue(ci(q[3]), forKey: "inputBottomLeft")
        guard let corrected = filter.outputImage, corrected.extent.width > 0, corrected.extent.height > 0 else { return nil }
        let e = corrected.extent
        let fitted = corrected
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(fitted.composited(over: white), from: CGRect(x: 0, y: 0, width: width, height: height),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
