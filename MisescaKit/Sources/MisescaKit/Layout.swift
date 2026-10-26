import Foundation

/// A point on the plan, in feet. Origin is the room's top-left corner,
/// x runs to the right and y runs down the page.
public struct PlanPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: PlanPoint, s: Double) -> PlanPoint { PlanPoint(x: a.x * s, y: a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public func dot(_ o: PlanPoint) -> Double { x * o.x + y * o.y }
    public func distance(to o: PlanPoint) -> Double { (self - o).length }

    public var normalized: PlanPoint {
        let l = length
        return l > 0 ? PlanPoint(x: x / l, y: y / l) : PlanPoint(x: 0, y: 0)
    }

    /// Rotates by `degrees`. With y pointing down the page this turns clockwise on screen.
    public func rotated(degrees: Double) -> PlanPoint {
        let r = degrees * .pi / 180
        return PlanPoint(x: x * cos(r) - y * sin(r), y: x * sin(r) + y * cos(r))
    }
}

public struct EventLayout: Codable, Hashable, Sendable {
    public var event: EventInfo
    public var room: RoomSize
    public var referencePoints: ReferencePoints
    public var items: [LayoutItem]
    public var aisles: [Aisle]

    enum CodingKeys: String, CodingKey {
        case event, room, items, aisles
        case referencePoints = "reference_points"
    }

    public init(event: EventInfo, room: RoomSize, referencePoints: ReferencePoints, items: [LayoutItem], aisles: [Aisle]) {
        self.event = event
        self.room = room
        self.referencePoints = referencePoints
        self.items = items
        self.aisles = aisles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(EventInfo.self, forKey: .event)
        room = try c.decode(RoomSize.self, forKey: .room)
        referencePoints = try c.decode(ReferencePoints.self, forKey: .referencePoints)
        items = try c.decode([LayoutItem].self, forKey: .items)
        aisles = try c.decodeIfPresent([Aisle].self, forKey: .aisles) ?? []
    }

    /// Items a crew sets and marks: everything except aisles.
    public var tables: [LayoutItem] { items.filter { $0.type.isTable } }

    public var counts: LayoutCounts {
        LayoutCounts(
            rounds: items.filter { $0.type == .roundTable }.count,
            banquetTables: items.filter { $0.type == .banquetTable }.count,
            ovalTables: items.filter { $0.type == .ovalTable }.count,
            stages: items.filter { $0.type == .stage }.count,
            bars: items.filter { $0.type == .bar }.count,
            danceFloors: items.filter { $0.type == .danceFloor }.count,
            seats: items.reduce(0) { $0 + ($1.seats ?? 0) }
        )
    }

    public func item(id: String) -> LayoutItem? { items.first { $0.id == id } }
}

public struct LayoutCounts: Hashable, Sendable {
    public var rounds: Int
    public var banquetTables: Int
    public var ovalTables: Int
    public var stages: Int
    public var bars: Int
    public var danceFloors: Int
    public var seats: Int
}

public struct EventInfo: Codable, Hashable, Sendable {
    public var name: String
    public var room: String
    public var start: Date?
    public var guests: Int?

    public init(name: String, room: String, start: Date?, guests: Int?) {
        self.name = name
        self.room = room
        self.start = start
        self.guests = guests
    }
}

public struct RoomSize: Codable, Hashable, Sendable {
    public var widthFt: Double
    public var depthFt: Double

    enum CodingKeys: String, CodingKey {
        case widthFt = "width_ft"
        case depthFt = "depth_ft"
    }

    public init(widthFt: Double, depthFt: Double) {
        self.widthFt = widthFt
        self.depthFt = depthFt
    }

    public func contains(_ p: PlanPoint, margin: Double = 0) -> Bool {
        p.x >= -margin && p.y >= -margin && p.x <= widthFt + margin && p.y <= depthFt + margin
    }
}

public struct ReferencePoints: Codable, Hashable, Sendable {
    public var a: ReferencePoint
    public var b: ReferencePoint

    enum CodingKeys: String, CodingKey {
        case a = "A"
        case b = "B"
    }

    public init(a: ReferencePoint, b: ReferencePoint) {
        self.a = a
        self.b = b
    }
}

public struct ReferencePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// Shown to the crew, for example "Stage front, center".
    public var label: String
    /// Short landmark used in directions, for example "stage" in "toward the stage".
    public var name: String?

    public init(x: Double, y: Double, label: String, name: String? = nil) {
        self.x = x
        self.y = y
        self.label = label
        self.name = name
    }

    public var point: PlanPoint { PlanPoint(x: x, y: y) }

    /// "stage" from an explicit name, otherwise the label up to its first comma, lowercased.
    public var landmark: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let head = label.split(separator: ",").first.map(String.init) ?? label
        return head.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

public enum ItemType: String, Codable, CaseIterable, Sendable {
    case roundTable = "round_table"
    case banquetTable = "banquet_table"
    /// An oval or racetrack table, sized by its length and width.
    case ovalTable = "oval_table"
    case stage
    case bar
    case danceFloor = "dance_floor"

    public var isTable: Bool { self == .roundTable || self == .banquetTable || self == .ovalTable }
    /// Drawn and built with a curved outline: rounds, and ovals inside their length and width.
    public var isCurved: Bool { self == .roundTable || self == .ovalTable }
}

public struct LayoutItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: ItemType
    public var label: String?
    public var x: Double
    public var y: Double
    public var diameterFt: Double?
    public var lengthFt: Double?
    public var widthFt: Double?
    public var rotation: Double?
    public var seats: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, label, x, y, rotation, seats
        case diameterFt = "diameter_ft"
        case lengthFt = "length_ft"
        case widthFt = "width_ft"
    }

    public init(id: String, type: ItemType, label: String? = nil, x: Double, y: Double,
                diameterFt: Double? = nil, lengthFt: Double? = nil, widthFt: Double? = nil,
                rotation: Double? = nil, seats: Int? = nil) {
        self.id = id
        self.type = type
        self.label = label
        self.x = x
        self.y = y
        self.diameterFt = diameterFt
        self.lengthFt = lengthFt
        self.widthFt = widthFt
        self.rotation = rotation
        self.seats = seats
    }

    public var center: PlanPoint { PlanPoint(x: x, y: y) }
    public var rotationDegrees: Double { rotation ?? 0 }

    /// Size along the item's own axes, in feet. Rounds are as long as they are wide.
    public var size: (length: Double, width: Double) {
        if type == .roundTable {
            let d = diameterFt ?? 0
            return (d, d)
        }
        return (lengthFt ?? 0, widthFt ?? 0)
    }

    public var footprint: Footprint {
        Footprint(center: center, length: size.length, width: size.width, rotationDegrees: rotationDegrees)
    }

    /// What the crew calls it: "Table 14", "Gift table", "Stage".
    public var displayName: String {
        if let label, !label.isEmpty {
            if type.isTable, label.allSatisfy(\.isNumber) { return "Table \(label)" }
            return label
        }
        switch type {
        case .roundTable, .banquetTable, .ovalTable: return "Table \(id)"
        case .stage: return "Stage"
        case .bar: return "Bar"
        case .danceFloor: return "Dance floor"
        }
    }

    /// Short text for the plan and AR labels: "14", "Gift", "Stage".
    public var shortLabel: String {
        if let label, !label.isEmpty { return label }
        return displayName
    }
}

public struct Aisle: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String?
    public var from: PlanPoint
    public var to: PlanPoint
    public var minWidthFt: Double

    enum CodingKeys: String, CodingKey {
        case id, label, from, to
        case minWidthFt = "min_width_ft"
    }

    public init(id: String, label: String? = nil, from: PlanPoint, to: PlanPoint, minWidthFt: Double) {
        self.id = id
        self.label = label
        self.from = from
        self.to = to
        self.minWidthFt = minWidthFt
    }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return "Aisle \(id)"
    }
}
