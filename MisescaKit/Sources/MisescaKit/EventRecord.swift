import Foundation

public enum EventStatus: String, Codable, Sendable {
    case notStarted, setting, enPlace, needsAttention

    public var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .setting: return "Setting"
        case .enPlace: return "En place"
        case .needsAttention: return "Needs attention"
        }
    }
}

/// One event on the phone: its layout, what the crew has marked, and the last check.
public struct EventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var layout: EventLayout
    /// Item ids marked en place, in the order they were marked, so undo can step back.
    public var placed: [String]
    public var lastReport: CheckReport?
    public var addedAt: Date

    public init(id: UUID = UUID(), layout: EventLayout, placed: [String] = [], lastReport: CheckReport? = nil, addedAt: Date = Date()) {
        self.id = id
        self.layout = layout
        self.placed = placed
        self.lastReport = lastReport
        self.addedAt = addedAt
    }

    public var placedCount: Int { Set(placed).intersection(layout.items.map(\.id)).count }
    public var totalCount: Int { layout.items.count }
    public func isPlaced(_ id: String) -> Bool { placed.contains(id) }

    /// The last check decides when there is one. Otherwise progress does.
    public var status: EventStatus {
        if let r = lastReport { return r.isClean ? .enPlace : .needsAttention }
        if placedCount == 0 { return .notStarted }
        return placedCount >= totalCount ? .enPlace : .setting
    }

    public mutating func markPlaced(_ id: String) {
        guard layout.item(id: id) != nil, !placed.contains(id) else { return }
        placed.append(id)
    }

    @discardableResult
    public mutating func undoLastMark() -> String? {
        placed.popLast()
    }

    /// Takes one item back to not set, wherever it is in the undo order.
    public mutating func unmark(_ id: String) {
        placed.removeAll { $0 == id }
    }
}
