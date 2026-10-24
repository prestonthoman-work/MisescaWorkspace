import Foundation

/// Something the room scan found, already converted to plan coordinates.
public struct DetectedObject: Hashable, Sendable {
    public var footprint: Footprint
    public var isTable: Bool

    public init(footprint: Footprint, isTable: Bool) {
        self.footprint = footprint
        self.isTable = isTable
    }
}

public struct CheckSettings: Sendable {
    /// A table within this distance of its plan position is en place.
    public var toleranceFt: Double
    /// Detected tables farther than this from any plan table aren't matched to it.
    public var matchRadiusFt: Double

    public init(toleranceInches: Double = 12, matchRadiusFt: Double = 5) {
        self.toleranceFt = toleranceInches / 12
        self.matchRadiusFt = matchRadiusFt
    }

    public var toleranceInches: Double { toleranceFt * 12 }
}

public enum TableMatcher {
    public struct Match: Hashable, Sendable {
        public var planIndex: Int
        public var detectedIndex: Int
        public var distance: Double
    }

    /// Greedy nearest-neighbor matching: closest pairs first, each side used once.
    public static func match(plan: [PlanPoint], detected: [PlanPoint], radius: Double) -> [Match] {
        var pairs: [Match] = []
        for (i, p) in plan.enumerated() {
            for (j, d) in detected.enumerated() {
                let dist = p.distance(to: d)
                if dist <= radius { pairs.append(Match(planIndex: i, detectedIndex: j, distance: dist)) }
            }
        }
        pairs.sort { ($0.distance, $0.planIndex, $0.detectedIndex) < ($1.distance, $1.planIndex, $1.detectedIndex) }
        var usedPlan = Set<Int>(), usedDetected = Set<Int>()
        var result: [Match] = []
        for m in pairs where !usedPlan.contains(m.planIndex) && !usedDetected.contains(m.detectedIndex) {
            usedPlan.insert(m.planIndex)
            usedDetected.insert(m.detectedIndex)
            result.append(m)
        }
        return result
    }
}

public enum AisleChecker {
    /// Sample spacing along the aisle, in feet.
    static let step = 0.5
    /// Aisle ends usually meet a stage, wall or door, so the first and last foot aren't measured.
    static let endTrim = 1.0

    /// Measures the narrowest clear width along an aisle. At each sample point it looks
    /// sideways both ways to the nearest detected object or wall and adds the two distances.
    public static func measure(_ aisle: Aisle, obstacles: [Footprint], room: RoomSize) -> AisleResult {
        let axis = aisle.to - aisle.from
        let length = axis.length
        let dir = axis.normalized
        let normal = PlanPoint(x: -dir.y, y: dir.x)
        let back = normal * -1

        var start = endTrim, end = length - endTrim
        if end < start { start = length / 2; end = length / 2 }

        var narrowest = Double.infinity
        var narrowestAt = aisle.from + dir * start
        var t = start
        while t <= end + 1e-9 {
            let s = aisle.from + dir * t
            let width: Double
            if obstacles.contains(where: { $0.contains(s) }) {
                width = 0
            } else {
                width = clearance(from: s, toward: normal, obstacles: obstacles, room: room)
                    + clearance(from: s, toward: back, obstacles: obstacles, room: room)
            }
            if width < narrowest {
                narrowest = width
                narrowestAt = s
            }
            t += step
        }
        return AisleResult(aisleID: aisle.id, measuredFt: narrowest, requiredFt: aisle.minWidthFt, narrowestAt: narrowestAt)
    }

    static func clearance(from p: PlanPoint, toward d: PlanPoint, obstacles: [Footprint], room: RoomSize) -> Double {
        var best = room.distanceToWall(from: p, direction: d)
        for o in obstacles {
            if let t = o.rayEntry(from: p, direction: d), t < best { best = t }
        }
        return best
    }
}

public enum ReportBuilder {
    /// Builds a report from a full room scan.
    public static func roomScan(layout: EventLayout, detected: [DetectedObject], settings: CheckSettings, date: Date = Date()) -> CheckReport {
        let planTables = layout.tables
        let nonTableItems = layout.items.filter { !$0.type.isTable }

        // Detected "tables" sitting on a stage, bar or dance floor, or outside the room,
        // aren't banquet furniture the crew set. Leave them out of matching.
        let inRoom = detected.filter { obj in
            guard obj.isTable else { return false }
            let c = obj.footprint.center
            guard layout.room.contains(c, margin: 2) else { return false }
            return !nonTableItems.contains { $0.footprint.inflated(by: 1).contains(c) }
        }
        let candidates = splitMergedTables(inRoom, planTables: planTables, matchRadius: settings.matchRadiusFt)

        let matches = TableMatcher.match(plan: planTables.map(\.center),
                                         detected: candidates.map(\.footprint.center),
                                         radius: settings.matchRadiusFt)
        var byPlan: [Int: TableMatcher.Match] = [:]
        for m in matches { byPlan[m.planIndex] = m }
        let matchedDetected = Set(matches.map(\.detectedIndex))

        let tables = planTables.enumerated().map { i, item -> TableResult in
            guard let m = byPlan[i] else { return TableResult(itemID: item.id, status: .missing) }
            let offset = candidates[m.detectedIndex].footprint.center - item.center
            let status: TableResult.Status = offset.length <= settings.toleranceFt ? .enPlace : .off
            return TableResult(itemID: item.id, status: status, offset: offset)
        }

        let extras = candidates.enumerated()
            .filter { !matchedDetected.contains($0.offset) }
            .map { ExtraTable(footprint: $0.element.footprint) }

        let obstacles = detected.map(\.footprint)
        let aisles = layout.aisles.map { AisleChecker.measure($0, obstacles: obstacles, room: layout.room) }

        return CheckReport(date: date, method: .roomScan, toleranceInches: settings.toleranceInches,
                           tables: tables, extras: extras, aisles: aisles)
    }

    /// Tables pushed together often come back from the scan as one long table. When a detection is
    /// clearly bigger than any nearby plan table, look for the nearest group of plan tables that,
    /// moved together, fills it. Treat the detection as those tables, each shifted by the same amount.
    static func splitMergedTables(_ detected: [DetectedObject], planTables: [LayoutItem], matchRadius: Double) -> [DetectedObject] {
        var claimed = Set<String>()
        var out: [DetectedObject] = []
        for obj in detected {
            let f = obj.footprint
            let area = f.length * f.width
            let reach = max(f.length, f.width) / 2 + matchRadius
            let nearby = planTables
                .filter { !claimed.contains($0.id) && $0.center.distance(to: f.center) <= reach }
                .sorted { $0.center.distance(to: f.center) < $1.center.distance(to: f.center) }
            let largest = nearby.map { $0.size.length * $0.size.width }.max() ?? 0

            var group: [LayoutItem] = []
            var shift = PlanPoint(x: 0, y: 0)
            if nearby.count >= 2, area > largest * 1.5 {
                for k in stride(from: nearby.count, through: 2, by: -1) {
                    let members = Array(nearby.prefix(k))
                    let total = members.reduce(0) { $0 + $1.size.length * $1.size.width }
                    guard total >= area * 0.6, total <= area * 1.3 else { continue }
                    let centroid = members.reduce(PlanPoint(x: 0, y: 0)) { $0 + $1.center } * (1 / Double(k))
                    let d = f.center - centroid
                    if members.allSatisfy({ f.inflated(by: 0.5).contains($0.center + d) }) {
                        group = members
                        shift = d
                        break
                    }
                }
            }

            if group.isEmpty {
                out.append(obj)
                continue
            }
            for m in group {
                claimed.insert(m.id)
                var part = m.footprint
                part.center = m.center + shift
                out.append(DetectedObject(footprint: part, isTable: true))
            }
        }
        return out
    }

    /// The table a point-and-check tap refers to: the nearest plan table within the match radius.
    public static func nearestTable(to p: PlanPoint, in layout: EventLayout, settings: CheckSettings) -> LayoutItem? {
        layout.tables
            .filter { $0.center.distance(to: p) <= settings.matchRadiusFt }
            .min { $0.center.distance(to: p) < $1.center.distance(to: p) }
    }

    /// Builds a report from tables checked one at a time. Later checks of the same table replace earlier ones.
    public static func pointCheck(layout: EventLayout, checks: [PlanPoint], settings: CheckSettings, date: Date = Date()) -> CheckReport {
        var latest: [String: PlanPoint] = [:]
        for p in checks {
            if let table = nearestTable(to: p, in: layout, settings: settings) {
                latest[table.id] = p - table.center
            }
        }
        let tables = layout.tables.map { item -> TableResult in
            guard let offset = latest[item.id] else { return TableResult(itemID: item.id, status: .notChecked) }
            return TableResult(itemID: item.id, status: offset.length <= settings.toleranceFt ? .enPlace : .off, offset: offset)
        }
        return CheckReport(date: date, method: .pointCheck, toleranceInches: settings.toleranceInches,
                           tables: tables, extras: [], aisles: [])
    }
}
