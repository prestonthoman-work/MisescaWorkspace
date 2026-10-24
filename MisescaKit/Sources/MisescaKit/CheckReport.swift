import Foundation

/// The outcome of a Mise Check, kept with the event.
public struct CheckReport: Codable, Hashable, Sendable {
    public enum Method: String, Codable, Sendable {
        case roomScan
        case pointCheck
    }

    public var date: Date
    public var method: Method
    public var toleranceInches: Double
    public var tables: [TableResult]
    public var extras: [ExtraTable]
    public var aisles: [AisleResult]

    public init(date: Date, method: Method, toleranceInches: Double,
                tables: [TableResult], extras: [ExtraTable], aisles: [AisleResult]) {
        self.date = date
        self.method = method
        self.toleranceInches = toleranceInches
        self.tables = tables
        self.extras = extras
        self.aisles = aisles
    }

    public func count(_ s: TableResult.Status) -> Int { tables.filter { $0.status == s }.count }
    public var narrowAisles: [AisleResult] { aisles.filter { !$0.passes } }

    public var issueCount: Int {
        count(.off) + count(.missing) + extras.count + narrowAisles.count
    }

    /// Every table checked, nothing off, missing or extra, every aisle clear.
    public var isClean: Bool { issueCount == 0 && count(.notChecked) == 0 }

    /// "26 en place, 2 off, 1 missing, 1 aisle too narrow."
    public var summary: String {
        var parts = ["\(count(.enPlace)) en place"]
        if count(.off) > 0 { parts.append("\(count(.off)) off") }
        if count(.missing) > 0 { parts.append("\(count(.missing)) missing") }
        if !extras.isEmpty { parts.append("\(extras.count) extra") }
        let narrow = narrowAisles.count
        if narrow > 0 { parts.append("\(narrow) \(narrow == 1 ? "aisle" : "aisles") too narrow") }
        if count(.notChecked) > 0 { parts.append("\(count(.notChecked)) not checked") }
        return parts.joined(separator: ", ") + "."
    }
}

public struct TableResult: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case enPlace, off, missing, notChecked
    }

    public var itemID: String
    public var status: Status
    /// Where the real table is relative to its plan position, in feet.
    public var offset: PlanPoint?

    public var id: String { itemID }

    public init(itemID: String, status: Status, offset: PlanPoint? = nil) {
        self.itemID = itemID
        self.status = status
        self.offset = offset
    }
}

/// A table found in the room that isn't in the plan.
public struct ExtraTable: Codable, Hashable, Identifiable, Sendable {
    public var footprint: Footprint
    public var id: String { "\(footprint.center.x),\(footprint.center.y)" }

    public init(footprint: Footprint) { self.footprint = footprint }
}

public struct AisleResult: Codable, Hashable, Identifiable, Sendable {
    public var aisleID: String
    public var measuredFt: Double
    public var requiredFt: Double
    /// Where along the aisle it is narrowest.
    public var narrowestAt: PlanPoint

    public var id: String { aisleID }
    public var passes: Bool { measuredFt + 1e-9 >= requiredFt }

    public init(aisleID: String, measuredFt: Double, requiredFt: Double, narrowestAt: PlanPoint) {
        self.aisleID = aisleID
        self.measuredFt = measuredFt
        self.requiredFt = requiredFt
        self.narrowestAt = narrowestAt
    }
}

/// Plain-language wording for results, phrased from the room's own landmarks.
public struct Wording: Sendable {
    public var layout: EventLayout

    public init(layout: EventLayout) { self.layout = layout }

    /// "toward the stage" / "toward the main entrance", plus left and right as seen facing landmark A.
    public func direction(of offset: PlanPoint) -> String {
        let a = layout.referencePoints.a, b = layout.referencePoints.b
        let facing = (a.point - b.point).normalized
        let right = PlanPoint(x: -facing.y, y: facing.x)
        let along = offset.dot(facing)
        let side = offset.dot(right)
        let alongText = along >= 0 ? "toward the \(a.landmark)" : "toward the \(b.landmark)"
        let sideText = side >= 0 ? "to the right" : "to the left"

        if abs(side) < 0.4 * abs(along) { return alongText }
        if abs(along) < 0.4 * abs(side) { return "\(sideText), facing the \(a.landmark)" }
        return "\(alongText) and \(sideText)"
    }

    public func message(for result: TableResult) -> String {
        let name = layout.item(id: result.itemID)?.displayName ?? result.itemID
        switch result.status {
        case .enPlace:
            return "\(name) is en place."
        case .missing:
            return "\(name) is missing."
        case .notChecked:
            return "\(name) hasn't been checked."
        case .off:
            guard let o = result.offset else { return "\(name) is off." }
            let dist = Units.describe(feet: o.length)
            let dir = direction(of: o)
            if dir.contains(" and ") { return "\(name) is \(dist) off, \(dir)." }
            return "\(name) is \(dist) \(dir)."
        }
    }

    public func message(for extra: ExtraTable) -> String {
        "Extra table \(direction(ofPoint: extra.footprint.center))."
    }

    public func message(for aisle: AisleResult) -> String {
        let name = layout.aisles.first { $0.id == aisle.aisleID }?.displayName ?? aisle.aisleID
        let need = Units.describe(feet: aisle.requiredFt)
        if aisle.measuredFt < 0.5 { return "\(name) is blocked. Plan calls for \(need)." }
        return "\(name) is \(Units.describe(feet: aisle.measuredFt)). Plan calls for \(need)."
    }

    /// Rough location of a spot, by nearest table: "near Table 9".
    public func direction(ofPoint p: PlanPoint) -> String {
        guard let nearest = layout.tables.min(by: { $0.center.distance(to: p) < $1.center.distance(to: p) }) else {
            return "in the room"
        }
        return "near \(nearest.displayName)"
    }
}
