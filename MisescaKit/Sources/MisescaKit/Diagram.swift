import Foundation
import CoreGraphics

/// A table-like shape found in a diagram image. Units are image pixels, y down.
public struct DiagramShape: Hashable, Sendable {
    public enum Kind: String, Sendable { case circle, rectangle }
    public var kind: Kind
    public var center: PlanPoint
    /// Diameter for circles, long side for rectangles.
    public var length: Double
    public var width: Double
    public var rotationDegrees: Double

    public init(kind: Kind, center: PlanPoint, length: Double, width: Double, rotationDegrees: Double) {
        self.kind = kind
        self.center = center
        self.length = length
        self.width = width
        self.rotationDegrees = rotationDegrees
    }
}

/// Text read from a diagram image, such as a table number. Units are image pixels, y down.
public struct DiagramText: Hashable, Sendable {
    public var text: String
    public var center: PlanPoint

    public init(text: String, center: PlanPoint) {
        self.text = text
        self.center = center
    }
}

public struct DiagramReading: Sendable {
    public var imageWidth: Double
    public var imageHeight: Double
    public var shapes: [DiagramShape]
    public var texts: [DiagramText]

    public init(imageWidth: Double, imageHeight: Double, shapes: [DiagramShape], texts: [DiagramText]) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.shapes = shapes
        self.texts = texts
    }
}

/// Ties image pixels to feet. The user taps the room's top-left and bottom-right corners
/// and enters the room width; diagrams are drawn to one scale, so the depth follows.
public struct DiagramCalibration: Hashable, Sendable {
    public var topLeft: PlanPoint
    public var bottomRight: PlanPoint
    public var widthFt: Double

    public init(topLeft: PlanPoint, bottomRight: PlanPoint, widthFt: Double) {
        self.topLeft = topLeft
        self.bottomRight = bottomRight
        self.widthFt = widthFt
    }

    public var isValid: Bool {
        bottomRight.x - topLeft.x > 10 && bottomRight.y - topLeft.y > 10 && widthFt > 0
    }

    public var feetPerPixel: Double { widthFt / (bottomRight.x - topLeft.x) }
    public var depthFt: Double { (bottomRight.y - topLeft.y) * feetPerPixel }
    public var room: RoomSize { RoomSize(widthFt: widthFt, depthFt: depthFt) }

    public func plan(_ pixel: PlanPoint) -> PlanPoint { (pixel - topLeft) * feetPerPixel }
    public func pixel(_ plan: PlanPoint) -> PlanPoint { topLeft + plan * (1 / feetPerPixel) }
}

/// Classifies one traced outline as a circle or rectangle, or neither.
public enum ShapeClassifier {
    public static func classify(_ points: [PlanPoint]) -> DiagramShape? {
        guard points.count >= 4 else { return nil }
        let area = abs(signedArea(points))
        guard area > 30 else { return nil }
        var perimeter = 0.0
        for i in points.indices { perimeter += points[i].distance(to: points[(i + 1) % points.count]) }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bw = xs.max()! - xs.min()!, bh = ys.max()! - ys.min()!
        let center = PlanPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)

        // Traced outlines step pixel by pixel, which lengthens the perimeter, so the bar is below 1.
        let circularity = 4 * .pi * area / (perimeter * perimeter)
        let aspect = bw / max(bh, 1e-9)
        if points.count >= 8, circularity > 0.8, aspect > 0.85, aspect < 1.18 {
            return DiagramShape(kind: .circle, center: center, length: 2 * (area / .pi).squareRoot(),
                                width: 2 * (area / .pi).squareRoot(), rotationDegrees: 0)
        }

        guard let rect = minimumAreaRectangle(convexHull(points)), rect.area > 0 else { return nil }
        guard area / rect.area > 0.88 else { return nil }
        return DiagramShape(kind: .rectangle, center: rect.center, length: rect.length, width: rect.width,
                            rotationDegrees: rect.rotationDegrees)
    }

    static func signedArea(_ p: [PlanPoint]) -> Double {
        var a = 0.0
        for i in p.indices {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return a / 2
    }

    static func convexHull(_ points: [PlanPoint]) -> [PlanPoint] {
        let p = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard p.count > 2 else { return p }
        func cross(_ o: PlanPoint, _ a: PlanPoint, _ b: PlanPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [PlanPoint] = [], upper: [PlanPoint] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    struct OrientedRect {
        var center: PlanPoint
        var length: Double
        var width: Double
        var rotationDegrees: Double
        var area: Double { length * width }
    }

    /// The smallest rectangle around a convex hull has one side along a hull edge.
    static func minimumAreaRectangle(_ hull: [PlanPoint]) -> OrientedRect? {
        guard hull.count >= 3 else { return nil }
        var best: OrientedRect?
        for i in hull.indices {
            let edge = (hull[(i + 1) % hull.count] - hull[i]).normalized
            guard edge.length > 0 else { continue }
            let normal = PlanPoint(x: -edge.y, y: edge.x)
            let us = hull.map { $0.dot(edge) }, vs = hull.map { $0.dot(normal) }
            let (u0, u1, v0, v1) = (us.min()!, us.max()!, vs.min()!, vs.max()!)
            let a = (u1 - u0) * (v1 - v0)
            if best == nil || a < best!.area {
                let c = edge * ((u0 + u1) / 2) + normal * ((v0 + v1) / 2)
                var length = u1 - u0, width = v1 - v0
                var angle = atan2(edge.y, edge.x) * 180 / .pi
                if width > length {
                    swap(&length, &width)
                    angle += 90
                }
                angle = angle.truncatingRemainder(dividingBy: 180)
                if angle < 0 { angle += 180 }
                if angle > 179.5 { angle = 0 }
                best = OrientedRect(center: c, length: length, width: width, rotationDegrees: angle)
            }
        }
        return best
    }
}

/// Turns what was found in a diagram into layout items, using real-world sizes to tell
/// tables from text, the room outline and everything else.
public enum DiagramLayoutBuilder {
    /// Plausible table sizes, in feet.
    static let roundDiameter = 2.5...8.0
    static let banquetLength = 3.5...12.0
    static let banquetWidth = 1.5...4.0

    public static func items(from reading: DiagramReading, calibration: DiagramCalibration) -> [LayoutItem] {
        let fpp = calibration.feetPerPixel
        let room = calibration.room

        // Shapes in feet, sized like tables, inside the room.
        var found: [(kind: ItemType, footprint: Footprint)] = []
        for s in reading.shapes {
            let center = calibration.plan(s.center)
            guard room.contains(center) else { continue }
            let length = s.length * fpp, width = s.width * fpp
            switch s.kind {
            case .circle where roundDiameter.contains(length):
                found.append((.roundTable, Footprint(center: center, length: length, width: length, rotationDegrees: 0)))
            case .rectangle where banquetLength.contains(length) && banquetWidth.contains(width) && length / width >= 1.6:
                found.append((.banquetTable, Footprint(center: center, length: length, width: width, rotationDegrees: s.rotationDegrees)))
            default:
                break
            }
        }

        // Stages and bars are only recognized when the diagram names them, since their sizes vary too much.
        var named: [(ItemType, String, Footprint)] = []
        for s in reading.shapes where s.kind == .rectangle {
            let center = calibration.plan(s.center)
            guard room.contains(center) else { continue }
            let f = Footprint(center: center, length: s.length * fpp, width: s.width * fpp, rotationDegrees: s.rotationDegrees)
            guard f.length < room.widthFt * 0.9, f.width > 1 else { continue }
            let words = reading.texts.filter { f.inflated(by: 1).contains(calibration.plan($0.center)) }.map(\.text)
            for w in words {
                let lower = w.lowercased()
                if lower.contains("stage") { named.append((.stage, w, f)); break }
                if lower.contains("bar") { named.append((.bar, w, f)); break }
            }
        }
        // A named piece wins over a table guess on the same spot.
        found.removeAll { f in named.contains { $0.2.contains(f.footprint.center) } }

        // A drawn outline traces twice, once on each side of the line. Keep the outer one.
        found.sort { $0.footprint.length * $0.footprint.width > $1.footprint.length * $1.footprint.width }
        var kept: [(kind: ItemType, footprint: Footprint)] = []
        for f in found where !kept.contains(where: { $0.footprint.contains(f.footprint.center) }) {
            kept.append(f)
        }
        // Reading order: top to bottom in rows, then left to right.
        kept.sort {
            let dy = $0.footprint.center.y - $1.footprint.center.y
            if abs(dy) > 2 { return dy < 0 }
            return $0.footprint.center.x < $1.footprint.center.x
        }

        // Labels: short text sitting on or right next to the table.
        let texts = reading.texts.compactMap { t -> (String, PlanPoint)? in
            let s = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.count <= 20 else { return nil }
            return (s, calibration.plan(t.center))
        }
        var usedLabels = Set<String>()
        var labels: [String?] = kept.map { k in
            let near = texts
                .filter { k.footprint.inflated(by: 1).contains($0.1) }
                .min { $0.1.distance(to: k.footprint.center) < $1.1.distance(to: k.footprint.center) }
            guard let label = near?.0, !usedLabels.contains(label) else { return nil }
            usedLabels.insert(label)
            return label
        }
        // Tables without a readable number get the next free numbers.
        var next = (usedLabels.compactMap(Int.init).max() ?? 0) + 1
        for i in labels.indices where labels[i] == nil {
            while usedLabels.contains(String(next)) { next += 1 }
            labels[i] = String(next)
            usedLabels.insert(String(next))
        }

        var ids = Set<String>()
        var pieces: [LayoutItem] = []
        var keptNamed: [(ItemType, String, Footprint)] = []
        for n in named.sorted(by: { $0.2.length * $0.2.width > $1.2.length * $1.2.width })
            where !keptNamed.contains(where: { $0.2.contains(n.2.center) }) {
            keptNamed.append(n)
        }
        for (type, word, f) in keptNamed {
            var id = type == .stage ? "STAGE" : "BAR"
            var k = 2
            while ids.contains(id) { id = (type == .stage ? "STAGE" : "BAR") + "\(k)"; k += 1 }
            ids.insert(id)
            pieces.append(LayoutItem(id: id, type: type, label: word, x: f.center.x, y: f.center.y,
                                     lengthFt: (f.length * 2).rounded() / 2, widthFt: (f.width * 2).rounded() / 2,
                                     rotation: f.rotationDegrees.rounded()))
        }
        return pieces + kept.enumerated().map { i, k in
            let label = labels[i] ?? String(i + 1)
            var id = "T\(label)".replacingOccurrences(of: " ", with: "-")
            if ids.contains(id) { id += "-\(i + 1)" }
            ids.insert(id)
            let f = k.footprint
            if k.kind == .roundTable {
                let d = (f.length * 2).rounded() / 2
                return LayoutItem(id: id, type: .roundTable, label: label, x: f.center.x, y: f.center.y,
                                  diameterFt: d, seats: defaultSeats(.roundTable, length: d))
            }
            let l = (f.length * 2).rounded() / 2, w = (f.width * 2).rounded() / 2
            return LayoutItem(id: id, type: .banquetTable, label: label, x: f.center.x, y: f.center.y,
                              lengthFt: l, widthFt: w, rotation: f.rotationDegrees.rounded(),
                              seats: defaultSeats(.banquetTable, length: l))
        }
    }

    /// Common seating: 60 in rounds seat 8, 72 in rounds seat 10, banquet tables about one per foot.
    public static func defaultSeats(_ type: ItemType, length: Double) -> Int {
        switch type {
        case .roundTable: return length >= 5.75 ? 10 : 8
        case .banquetTable: return max(2, Int(length.rounded(.down)))
        default: return 0
        }
    }
}
