import Foundation

/// A problem with a layout file, worded for the person who has to fix it.
public struct LayoutError: Error, Equatable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum LayoutLoader {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Use a date like 2026-11-07T19:00:00-08:00.")
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func parseDate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = local.date(from: s) { return d }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return local.date(from: s)
    }

    /// Decodes and validates a layout file.
    public static func load(_ data: Data) throws -> EventLayout {
        let layout: EventLayout
        do {
            layout = try decoder().decode(EventLayout.self, from: data)
        } catch let e as DecodingError {
            throw LayoutError(describe(e))
        }
        try validate(layout)
        return layout
    }

    public static func validate(_ layout: EventLayout) throws {
        func fail(_ s: String) throws -> Never { throw LayoutError(s) }

        if layout.event.name.trimmingCharacters(in: .whitespaces).isEmpty { try fail("The event needs a name.") }
        let room = layout.room
        guard room.widthFt > 0, room.depthFt > 0 else { try fail("Room width and depth must be more than 0 ft.") }
        guard room.widthFt <= 1000, room.depthFt <= 1000 else { try fail("Room is larger than 1000 ft on a side. Check the units are feet.") }

        let a = layout.referencePoints.a, b = layout.referencePoints.b
        for (name, p) in [("A", a), ("B", b)] {
            if !room.contains(p.point) { try fail("Reference point \(name) is outside the room.") }
            if p.label.trimmingCharacters(in: .whitespaces).isEmpty { try fail("Reference point \(name) needs a label so the crew knows where to tap.") }
        }
        if a.point.distance(to: b.point) < 6 {
            try fail("Reference points A and B are less than 6 ft apart. Pick two spots farther apart so the layout lines up accurately.")
        }

        guard !layout.items.isEmpty else { try fail("The layout has no items.") }
        var seen = Set<String>()
        for item in layout.items {
            let name = "Item \"\(item.id)\""
            if item.id.isEmpty { try fail("Every item needs an id.") }
            if !seen.insert(item.id).inserted { try fail("Two items share the id \"\(item.id)\". Each id must be unique.") }
            if !room.contains(item.center) { try fail("\(name) is outside the room.") }
            switch item.type {
            case .roundTable:
                guard let d = item.diameterFt, d > 0 else { try fail("\(name) is a round table and needs diameter_ft.") }
                if d > 20 { try fail("\(name) is \(Int(d)) ft across. Check diameter_ft.") }
            case .banquetTable, .stage, .bar, .danceFloor:
                guard let l = item.lengthFt, l > 0, let w = item.widthFt, w > 0 else {
                    try fail("\(name) needs length_ft and width_ft.")
                }
            }
            if let s = item.seats, s < 0 { try fail("\(name) has a negative seat count.") }
        }

        var aisleIDs = Set<String>()
        for aisle in layout.aisles {
            let name = "Aisle \"\(aisle.id)\""
            if !aisleIDs.insert(aisle.id).inserted { try fail("Two aisles share the id \"\(aisle.id)\".") }
            if aisle.minWidthFt <= 0 { try fail("\(name) needs a min_width_ft above 0.") }
            if aisle.from.distance(to: aisle.to) < 1 { try fail("\(name) is shorter than 1 ft. Check from and to.") }
            if !room.contains(aisle.from, margin: 0.01) || !room.contains(aisle.to, margin: 0.01) {
                try fail("\(name) runs outside the room.")
            }
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String {
            var s = ""
            for k in keys {
                if let i = k.intValue { s += "[\(i)]" } else { s += s.isEmpty ? k.stringValue : ".\(k.stringValue)" }
            }
            return s
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            let location = path(ctx.codingPath)
            return location.isEmpty ? "The file is missing \"\(key.stringValue)\"." : "\(location) is missing \"\(key.stringValue)\"."
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let p = path(ctx.codingPath)
            if p.isEmpty { return "This file isn't a Misesca layout." }
            return "\(p) has the wrong kind of value. \(hint(for: ctx.codingPath.last))"
        case .dataCorrupted(let ctx):
            let p = path(ctx.codingPath)
            if p.isEmpty { return "This isn't a Misesca layout file. Layout files end in .json, like the samples." }
            if ctx.codingPath.last?.stringValue == "type" {
                return "\(p) isn't a known item type. Use round_table, banquet_table, stage, bar or dance_floor."
            }
            return "\(p) can't be read. \(ctx.debugDescription)"
        @unknown default:
            return "This file isn't a Misesca layout."
        }
    }

    private static func hint(for key: CodingKey?) -> String {
        switch key?.stringValue {
        case "x", "y", "width_ft", "depth_ft", "diameter_ft", "length_ft", "rotation", "min_width_ft":
            return "It should be a number of feet."
        case "seats", "guests":
            return "It should be a whole number."
        default:
            return "Check it against the sample layout."
        }
    }
}
