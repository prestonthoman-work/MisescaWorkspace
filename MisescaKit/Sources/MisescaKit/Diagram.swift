import Foundation
import CoreGraphics

/// A table-like shape found in a diagram image. Units are image pixels, y down.
public struct DiagramShape: Hashable, Sendable {
    /// `other` is a closed shape that is neither round nor rectangular, such as an L-shaped bar
    /// or a half-moon table, measured by its turned bounding box. It only becomes an item when
    /// the diagram names it.
    public enum Kind: String, Sendable { case circle, ellipse, rectangle, other }
    public var kind: Kind
    public var center: PlanPoint
    /// Diameter for circles, long axis for ellipses, long side for rectangles.
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
    /// Size of the line of text, level, or zero when unknown.
    public var width: Double
    public var height: Double

    public init(text: String, center: PlanPoint, width: Double = 0, height: Double = 0) {
        self.text = text
        self.center = center
        self.width = width
        self.height = height
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

/// Ties image pixels to feet. The room's top-left and bottom-right corners bound the room;
/// the scale comes from a known room width or a known table size.
public struct DiagramCalibration: Hashable, Sendable {
    public var topLeft: PlanPoint
    public var bottomRight: PlanPoint
    public var feetPerPixel: Double

    public init(topLeft: PlanPoint, bottomRight: PlanPoint, feetPerPixel: Double) {
        self.topLeft = topLeft
        self.bottomRight = bottomRight
        self.feetPerPixel = feetPerPixel
    }

    public init(topLeft: PlanPoint, bottomRight: PlanPoint, widthFt: Double) {
        self.init(topLeft: topLeft, bottomRight: bottomRight, feetPerPixel: widthFt / max(bottomRight.x - topLeft.x, 1e-9))
    }

    public var isValid: Bool {
        bottomRight.x - topLeft.x > 10 && bottomRight.y - topLeft.y > 10 && feetPerPixel > 0
    }

    public var widthFt: Double { (bottomRight.x - topLeft.x) * feetPerPixel }
    public var depthFt: Double { (bottomRight.y - topLeft.y) * feetPerPixel }
    public var room: RoomSize { RoomSize(widthFt: widthFt, depthFt: depthFt) }

    public func plan(_ pixel: PlanPoint) -> PlanPoint { (pixel - topLeft) * feetPerPixel }
    public func pixel(_ plan: PlanPoint) -> PlanPoint { topLeft + plan * (1 / feetPerPixel) }
}

public enum DiagramScale {
    /// The drawn diameter, in pixels, shared by the most round tables. Diagrams use one or two
    /// standard sizes, so the biggest cluster is the house round. Nil when there are fewer than three.
    public static func typicalRoundDiameter(in reading: DiagramReading) -> Double? {
        typicalRound(in: reading.shapes)?.diameter
    }

    /// The house round: the largest drawn size that at least three round shapes share.
    /// Chairs are smaller and more numerous, cocktail tables smaller, so size wins over count.
    /// Also returns how oval those rounds came out (horizontal over vertical extent), which
    /// tells how far a straightened photo's proportions are off.
    public static func typicalRound(in shapes: [DiagramShape]) -> (diameter: Double, stretch: Double, spread: Double)? {
        let round = shapes.filter { s in
            s.kind == .circle || (s.kind == .ellipse && s.length / max(s.width, 1e-9) < 1.6)
        }.sorted { $0.length > $1.length }
        var outer: [DiagramShape] = []
        for c in round where !outer.contains(where: { $0.center.distance(to: c.center) < $0.width / 2 }) {
            outer.append(c)
        }
        func size(_ s: DiagramShape) -> Double { (s.length + s.width) / 2 }
        let candidates = outer.filter { size($0) >= 12 }
        func median(_ c: [DiagramShape]) -> Double { let v = c.map(size).sorted(); return v[v.count / 2] }
        let clusters = candidates
            .map { x in candidates.filter { abs(size($0) - size(x)) <= size(x) * 0.1 } }
            .filter { $0.count >= 3 }
        guard let largest = clusters.map(median).max() else { return nil }
        let best = clusters.filter { median($0) >= largest * 0.9 }.max { $0.count < $1.count } ?? []
        guard best.count >= 3 else { return nil }
        let stretches = best.map { s -> Double in
            guard s.kind == .ellipse else { return 1 }
            let a = s.length / 2, b = s.width / 2, t = s.rotationDegrees * .pi / 180
            let hx = (a * a * cos(t) * cos(t) + b * b * sin(t) * sin(t)).squareRoot()
            let vy = (a * a * sin(t) * sin(t) + b * b * cos(t) * cos(t)).squareRoot()
            return hx / vy
        }.sorted()
        // Diameter as if circular: the geometric mean of the axes keeps area.
        let diameters = best.map { ($0.length * $0.width).squareRoot() }.sorted()
        let median = diameters[diameters.count / 2]
        // How much same-size tables disagree: the middle half's range relative to the size.
        let spread = (diameters[diameters.count * 3 / 4] - diameters[diameters.count / 4]) / median
        return (median, stretches[stretches.count / 2], spread)
    }
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

/// Turns what was found in a diagram into layout items.
///
/// Evidence comes first: a shape the diagram calls a table is a table at any size or shape,
/// and bars, stages and dance floors are recognized when the diagram names them, or for a
/// dance floor, when it's drawn as a tiled floor. Unnamed shapes are tables when they are a
/// plausible table size and aren't chairs around a table or an area enclosing other tables.
public enum DiagramLayoutBuilder {
    /// Sizes, in feet, for shapes the diagram doesn't name. Wide on purpose: they only keep out
    /// chairs, line work and whole areas. Round tables:
    static let roundDiameter = 2.0...10.0
    /// Long tables (one side at least 1.6 times the other), down to 18 in classroom tables:
    static let longLength = 3.5...24.0
    static let longWidth = 1.25...8.0
    /// Square and near-square tables:
    static let squareSide = 2.0...12.0
    /// Below this a square is as likely a chair, column or speaker, so it counts only when it
    /// carries a number or name.
    static let labelOnlySide = 2.75
    /// Smallest shape that a "table" label can make a table, so the inside of a letter isn't one.
    static let namedMinimum = 1.0

    enum Name { case table, bar, stage, danceFloor }

    /// What a piece of text calls the object it's on. Whole words only, so "Barn" isn't a bar.
    static func name(of text: String) -> Name? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        if words.contains(where: isTableWord) { return .table }
        if words.contains(where: { $0 == "dance" || $0 == "dancefloor" }) { return .danceFloor }
        if words.contains(where: { $0 == "stage" || $0 == "riser" || $0 == "risers" }) { return .stage }
        if words.contains(where: { $0 == "bar" || $0 == "bars" }) { return .bar }
        return nil
    }

    /// "table", "tables", "tbl", or "table" misread by one letter ("tabie", "tabl").
    static func isTableWord(_ word: String) -> Bool {
        if word == "tables" || word == "tbl" { return true }
        guard word.count >= 4, word.count <= 6 else { return false }
        let target = Array("table")
        var prev = Array(0...target.count)
        for (i, ch) in word.enumerated() {
            var cur = [i + 1]
            for (j, t) in target.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ch == t ? 0 : 1)))
            }
            prev = cur
        }
        return prev[target.count] <= 1
    }

    /// "Table 7", "TABLE 7" and "Table #7" give "7", matching diagrams that write just the
    /// number. "Gift table" and "Table" alone stay as they are.
    static func tableNumber(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let word = trimmed.prefix { $0.isLetter }
        guard isTableWord(word.lowercased()) else { return trimmed }
        let rest = trimmed.dropFirst(word.count).trimmingCharacters(in: CharacterSet(charactersIn: " #:-."))
        return rest.isEmpty ? trimmed : rest
    }

    /// A shape in feet, with what the diagram calls it.
    struct Candidate {
        var kind: DiagramShape.Kind
        var footprint: Footprint
        var name: Name?
        var nameText: String?
        /// Small and square: a table only if it carries a number or name.
        var needsLabel = false
        var area: Double { footprint.length * footprint.width }
        var roundish: Bool { kind == .circle || (kind == .ellipse && footprint.length / footprint.width < 1.12) }
    }

    public static func items(from reading: DiagramReading, calibration: DiagramCalibration, includeUnlabeledSmall: Bool = false) -> [LayoutItem] {
        itemsAndGuesses(from: reading, calibration: calibration, includeUnlabeledSmall: includeUnlabeledSmall).items
    }

    /// Items, plus the ids of tables whose numbers couldn't be read and were filled in.
    /// `includeUnlabeledSmall` keeps small squares that have no number yet, so their numbers can be read.
    public static func itemsAndGuesses(from reading: DiagramReading, calibration: DiagramCalibration,
                                       includeUnlabeledSmall: Bool = false) -> (items: [LayoutItem], guessed: Set<String>) {
        let fpp = calibration.feetPerPixel
        let room = calibration.room
        let roomSpan = max(room.widthFt, room.depthFt)

        // Every shape inside the room, in feet. A slightly oval round is still a round;
        // straightening leaves a little error.
        var candidates: [Candidate] = reading.shapes.compactMap { s in
            let center = calibration.plan(s.center)
            guard room.contains(center) else { return nil }
            let length = s.length * fpp, width = s.width * fpp
            guard length < roomSpan * 0.9, width > 0.25 else { return nil }
            var c = Candidate(kind: s.kind, footprint: Footprint(center: center, length: length, width: width, rotationDegrees: s.rotationDegrees))
            if c.roundish {
                let d = (length + width) / 2
                c.footprint = Footprint(center: center, length: d, width: d, rotationDegrees: 0)
            }
            return c
        }

        // Names on the diagram go to the smallest shape they sit inside, or when written beside
        // an object, the largest one within a foot (the object, not a stool or chair next to it).
        // The letters themselves run together into a shape the size of the text; that isn't it.
        for t in reading.texts {
            guard let n = name(of: t.text) else { continue }
            let p = calibration.plan(t.center)
            let textArea = t.width * t.height * fpp * fpp
            let sized = candidates.indices.filter {
                min(candidates[$0].footprint.length, candidates[$0].footprint.width) >= namedMinimum && candidates[$0].area > textArea * 1.5
            }
            // A measured round or rectangle before a fragment of one cut up by the text.
            let inside = sized.filter { candidates[$0].footprint.contains(p) }
            let target = inside.min { (candidates[$0].kind == .other ? 1 : 0, candidates[$0].area) < (candidates[$1].kind == .other ? 1 : 0, candidates[$1].area) }
                ?? sized.filter { candidates[$0].footprint.inflated(by: 1).contains(p) }.max { candidates[$0].area < candidates[$1].area }
            if let i = target, candidates[i].name == nil {
                candidates[i].name = n
                candidates[i].nameText = t.text.trimmingCharacters(in: .whitespaces)
            }
        }

        var used = Set<Int>()
        var named: [(ItemType, String, Footprint)] = []

        // A dance floor drawn as tiles: nine or more matching squares packed edge to edge.
        // Tables are never packed like that, so the tiles aren't tables.
        for grid in tileGrids(candidates) {
            grid.cells.forEach { used.insert($0) }
            if let c = grid.container { used.insert(c) }
            let label = candidates.first { $0.name == .danceFloor && grid.footprint.contains($0.footprint.center) }?.nameText
            named.append((.danceFloor, label ?? "Dance floor", grid.footprint))
        }

        // Bars, stages and dance floors the diagram names, whatever their shape.
        for (i, c) in candidates.enumerated() where !used.contains(i) {
            let type: ItemType
            switch c.name {
            case .bar: type = .bar
            case .stage: type = .stage
            case .danceFloor: type = .danceFloor
            default: continue
            }
            guard min(c.footprint.length, c.footprint.width) >= namedMinimum else { continue }
            used.insert(i)
            named.append((type, c.nameText ?? "", c.footprint))
        }
        var keptNamed: [(ItemType, String, Footprint)] = []
        for n in named.sorted(by: { $0.2.length * $0.2.width > $1.2.length * $1.2.width })
            where !keptNamed.contains(where: { $0.2.contains(n.2.center) }) {
            keptNamed.append(n)
        }

        // Tables: named ones at any size, unnamed ones within table sizes.
        var tables: [Candidate] = []
        for (i, var c) in candidates.enumerated() where !used.contains(i) {
            // A named piece wins over a table guess on the same spot.
            guard !keptNamed.contains(where: { $0.2.contains(c.footprint.center) }) else { continue }
            let f = c.footprint
            if c.name == .table {
                guard min(f.length, f.width) >= namedMinimum else { continue }
            } else if c.kind == .other {
                continue
            } else if c.roundish {
                guard roundDiameter.contains(f.length) else { continue }
                c.needsLabel = f.length < labelOnlySide
            } else if f.length / f.width >= 1.6 {
                guard longLength.contains(f.length), longWidth.contains(f.width) else { continue }
            } else {
                guard squareSide.contains(f.length), squareSide.contains(f.width) else { continue }
                c.needsLabel = f.width < labelOnlySide
            }
            tables.append(c)
        }

        // Chairs: small unnamed shapes hugging the outside of a bigger table.
        let beforeChairs = tables
        tables.removeAll { t in
            guard t.name == nil else { return false }
            let size = t.footprint.length
            return beforeChairs.contains { b in
                b.footprint.width > size * 1.3 && !b.footprint.contains(t.footprint.center)
                    && b.footprint.inflated(by: size * 0.75 + 0.25).contains(t.footprint.center)
            }
        }
        // An outline around other, much smaller tables is an area, not a table. Shapes found
        // twice (inside and outside a drawn line) sit on the same center at nearly the same size,
        // and pieces of a table cut up by its label are too big to count.
        func sameSpot(_ a: Candidate, _ b: Candidate) -> Bool {
            a.footprint.center.distance(to: b.footprint.center) < min(a.footprint.width, b.footprint.width) * 0.25
                && min(a.area, b.area) / max(a.area, b.area) > 0.5
        }
        let all = tables
        tables.removeAll { a in
            let inside = all.filter { o in !sameSpot(a, o) && o.area < a.area * 0.35 && a.footprint.contains(o.footprint.center) }
            // An irregular outline gives way to a measured round or rectangle inside it.
            if a.kind == .other { return inside.contains { $0.kind != .other } }
            return inside.count >= 2
        }

        // A drawn outline traces twice, once on each side of the line. Keep the outer one.
        tables.sort { $0.area > $1.area }
        var kept: [Candidate] = []
        for t in tables where !kept.contains(where: { $0.footprint.contains(t.footprint.center) }) {
            kept.append(t)
        }
        // Reading order: top to bottom in rows, then left to right.
        kept.sort {
            let dy = $0.footprint.center.y - $1.footprint.center.y
            if abs(dy) > 2 { return dy < 0 }
            return $0.footprint.center.x < $1.footprint.center.x
        }

        // Labels: short text sitting on or right next to the table. Text that says "Table 12"
        // outright beats a bare number read nearer the middle.
        let texts = reading.texts.compactMap { t -> (String, PlanPoint, Int)? in
            let raw = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = tableNumber(raw)
            guard isPlausibleLabel(s) else { return nil }
            return (s, calibration.plan(t.center), s == raw ? 1 : 0)
        }
        var usedLabels = Set<String>()
        var labels: [String?] = kept.map { k in
            let near = texts
                .filter { k.footprint.inflated(by: 1).contains($0.1) }
                .min { ($0.2, $0.1.distance(to: k.footprint.center)) < ($1.2, $1.1.distance(to: k.footprint.center)) }
            guard let label = near?.0, !usedLabels.contains(label) else { return nil }
            usedLabels.insert(label)
            return label
        }
        // Small squares with nothing written on them are left out.
        if !includeUnlabeledSmall {
            let keep = kept.indices.filter { !kept[$0].needsLabel || labels[$0] != nil }
            kept = keep.map { kept[$0] }
            labels = keep.map { labels[$0] }
        }
        // Tables without a readable number get the next free numbers.
        var next = (usedLabels.compactMap(Int.init).filter { $0 <= 999 }.max() ?? 0) + 1
        let guessedIndices = Set(labels.indices.filter { labels[$0] == nil })
        for i in labels.indices where labels[i] == nil {
            while usedLabels.contains(String(next)) { next += 1 }
            labels[i] = String(next)
            usedLabels.insert(String(next))
        }

        var ids = Set<String>()
        var pieces: [LayoutItem] = []
        for (type, word, f) in keptNamed {
            let base = type == .stage ? "STAGE" : (type == .bar ? "BAR" : "DANCE")
            var id = base
            var k = 2
            while ids.contains(id) { id = base + "\(k)"; k += 1 }
            ids.insert(id)
            pieces.append(LayoutItem(id: id, type: type, label: word, x: f.center.x, y: f.center.y,
                                     lengthFt: (f.length * 2).rounded() / 2, widthFt: (f.width * 2).rounded() / 2,
                                     rotation: f.rotationDegrees.rounded()))
        }
        var guessedIDs = Set<String>()
        let items = kept.enumerated().map { i, k -> LayoutItem in
            let label = labels[i] ?? String(i + 1)
            var id = "T\(label)".replacingOccurrences(of: " ", with: "-")
            if ids.contains(id) { id += "-\(i + 1)" }
            ids.insert(id)
            let f = k.footprint
            if k.roundish {
                let d = (f.length * 2).rounded() / 2
                return LayoutItem(id: id, type: .roundTable, label: label, x: f.center.x, y: f.center.y,
                                  diameterFt: d, seats: defaultSeats(.roundTable, length: d))
            }
            let l = (f.length * 2).rounded() / 2, w = (f.width * 2).rounded() / 2
            if k.kind == .ellipse {
                return LayoutItem(id: id, type: .ovalTable, label: label, x: f.center.x, y: f.center.y,
                                  lengthFt: l, widthFt: w, rotation: f.rotationDegrees.rounded(),
                                  seats: defaultSeats(.ovalTable, length: l, width: w))
            }
            // Other shapes named as tables are kept by their outer size, as banquet tables.
            // A table-sized piece named on the diagram as a bar or stage is one.
            if let n = name(of: label), n == .bar || n == .stage {
                return LayoutItem(id: id, type: n == .bar ? .bar : .stage, label: label, x: f.center.x, y: f.center.y,
                                  lengthFt: l, widthFt: w, rotation: f.rotationDegrees.rounded())
            }
            return LayoutItem(id: id, type: .banquetTable, label: label, x: f.center.x, y: f.center.y,
                              lengthFt: l, widthFt: w, rotation: f.rotationDegrees.rounded(),
                              seats: defaultSeats(.banquetTable, length: l, width: w))
        }
        for (i, item) in items.enumerated() where guessedIndices.contains(i) { guessedIDs.insert(item.id) }
        return (pieces + items, guessedIDs)
    }

    struct TileGrid {
        var cells: [Int]
        /// An outline drawn around the tiles, which is the floor's true edge.
        var container: Int?
        var footprint: Footprint
    }

    /// Groups of six or more matching squares at least 2 ft across, turned the same way and
    /// packed edge to edge or corner to corner (a checkerboard), spanning three rows and columns.
    /// Six, not nine, because a label written across the floor hides some tiles.
    static func tileGrids(_ candidates: [Candidate]) -> [TileGrid] {
        let cells = candidates.indices.filter { i in
            let c = candidates[i]
            return c.kind == .rectangle && c.name != .table && c.footprint.length / c.footprint.width < 1.25 && c.footprint.width >= 2
        }
        func turn(_ c: Candidate) -> Double { c.footprint.rotationDegrees.truncatingRemainder(dividingBy: 90) }
        var parent = Dictionary(uniqueKeysWithValues: cells.map { ($0, $0) })
        func find(_ a: Int) -> Int { var a = a; while parent[a]! != a { a = parent[a]! }; return a }
        for (n, i) in cells.enumerated() {
            for j in cells[(n + 1)...] {
                let a = candidates[i], b = candidates[j]
                let size = (a.footprint.length + b.footprint.length) / 2
                var dt = abs(turn(a) - turn(b)); dt = min(dt, 90 - dt)
                guard abs(a.footprint.length - b.footprint.length) < size * 0.12, dt < 5,
                      a.footprint.center.distance(to: b.footprint.center) < size * 1.5 else { continue }
                let ra = find(i), rb = find(j)
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
        }
        let groups = Dictionary(grouping: cells, by: find).values.filter { $0.count >= 6 }
        return groups.compactMap { group in
            let angle = turn(candidates[group[0]])
            let size = group.map { candidates[$0].footprint.length }.reduce(0, +) / Double(group.count)
            // Lay the tiles out in their own frame to count rows and columns and find the edges.
            let local = group.map { candidates[$0].footprint.center.rotated(degrees: -angle) }
            let rows = Set(local.map { Int(($0.y / size).rounded()) }), cols = Set(local.map { Int(($0.x / size).rounded()) })
            guard rows.count >= 3, cols.count >= 3 else { return nil }
            let half = size / 2
            let x0 = local.map(\.x).min()! - half, x1 = local.map(\.x).max()! + half
            let y0 = local.map(\.y).min()! - half, y1 = local.map(\.y).max()! + half
            let center = PlanPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2).rotated(degrees: angle)
            var footprint = Footprint(center: center, length: x1 - x0, width: y1 - y0, rotationDegrees: angle)
            if footprint.width > footprint.length {
                footprint = Footprint(center: center, length: y1 - y0, width: x1 - x0, rotationDegrees: angle + 90)
            }
            // A drawn outline around the tiles is the floor's edge. It can be well bigger than the
            // tiles found, when edge tiles run into it or a label hides some.
            let area = footprint.length * footprint.width
            let container = candidates.indices.filter { i in
                !group.contains(i) && candidates[i].kind == .rectangle && candidates[i].footprint.contains(center)
                    && candidates[i].area >= area * 0.95 && candidates[i].area <= area * 3
            }.max { candidates[$0].area < candidates[$1].area }
            return TileGrid(cells: group, container: container, footprint: container.map { candidates[$0].footprint } ?? footprint)
        }
    }

    /// Words on the diagram naming a table, bar, stage or dance floor that no item was found
    /// under, so the person knows to add it.
    public static func namedWithoutOutline(_ texts: [DiagramText], items: [LayoutItem], calibration: DiagramCalibration) -> [String] {
        var out: [String] = []
        for t in texts {
            let s = t.text.trimmingCharacters(in: .whitespaces)
            guard name(of: s) != nil, !out.contains(s) else { continue }
            let p = calibration.plan(t.center)
            guard calibration.room.contains(p) else { continue }
            if !items.contains(where: { $0.footprint.inflated(by: 1.5).contains(p) }) { out.append(s) }
        }
        return out
    }

    /// Text that names or numbers something, as opposed to chairs or line work read as text.
    public static func isLabelOrName(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlausibleLabel(tableNumber(trimmed))
    }

    /// Table numbers run 1 to 999 without leading zeros; names are words. Anything else is
    /// more likely chairs or line work read as text, and is left for the person to fill in.
    static func isPlausibleLabel(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 20 else { return false }
        if s.allSatisfy(\.isNumber) {
            guard let n = Int(s), n >= 1, n <= 999, !s.hasPrefix("0") else { return false }
            return true
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'&#./"))
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let letters = s.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        // "oo oo do oo": mostly round letters is a row of chairs, not a word. Chairs seen side
        // on or with backs read as "UU", "nnna" or "JU".
        let lower = letters.lowercased()
        let round = lower.filter { "o0".contains($0) }.count
        let chairLike = lower.filter { "o0uncjdq".contains($0) }.count
        return Double(round) / Double(letters.count) < 0.5 && Double(chairLike) / Double(letters.count) < 0.75
    }

    /// Common seating: 60 in rounds seat 8, 72 in rounds seat 10, banquet tables about one per
    /// foot, square tables one or two a side, ovals one per 2 ft of edge.
    public static func defaultSeats(_ type: ItemType, length: Double, width: Double? = nil) -> Int {
        switch type {
        case .roundTable: return length >= 5.75 ? 10 : 8
        case .ovalTable:
            // Edge length of the ellipse (Ramanujan's approximation).
            let a = length / 2, b = (width ?? length * 0.5) / 2
            let h = ((a - b) * (a - b)) / ((a + b) * (a + b))
            let edge = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
            return max(4, Int((edge / 2).rounded(.down)))
        case .banquetTable:
            if let width, width >= length * 0.8 { return length >= 4.5 ? 8 : (length >= 2.5 ? 4 : 2) }
            return max(2, Int(length.rounded(.down)))
        default: return 0
        }
    }
}
