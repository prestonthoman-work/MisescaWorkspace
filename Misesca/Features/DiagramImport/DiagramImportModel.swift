import Foundation
import Observation
import UIKit
import MisescaKit

/// Steps for turning a diagram image into a layout. Every step ends with the person confirming;
/// nothing found in the image is saved without being looked at.
@MainActor
@Observable
final class DiagramImportModel {
    enum Step { case room, tables, points, details }

    let source: DiagramSource
    var step: Step = .room
    /// Reading runs while the person marks the room, so they rarely wait.
    private(set) var isReading = true
    var waitingToConfirm = false

    // Room
    var topLeft: PlanPoint?
    var bottomRight: PlanPoint?
    var widthText = ""

    // Tables, in plan feet
    var items: [LayoutItem] = []
    var selectedID: String?
    var foundCount = 0

    // Line-up points, in plan feet
    var pointA: PlanPoint?
    var pointB: PlanPoint?
    var labelA = "Stage front, center"
    var labelB = "Main entrance, center"

    // Details
    var eventName: String
    var roomName = ""
    var hasDate = false
    var date = Date()
    var guestsText = ""

    @ObservationIgnored private var reading: DiagramReading?
    @ObservationIgnored private var addedCount = 0

    init(source: DiagramSource) {
        self.source = source
        eventName = source.suggestedName
    }

    var imageSize: CGSize { source.image.size }

    func read() async {
        guard reading == nil else { return }
        let empty = DiagramReading(imageWidth: Double(imageSize.width), imageHeight: Double(imageSize.height), shapes: [], texts: [])
        if let cg = source.image.cgImage {
            // If tracing fails, the person can still mark everything by hand.
            reading = (try? await Task.detached(priority: .userInitiated) { try DiagramReader.read(cg) }.value) ?? empty
        } else {
            reading = empty
        }
        isReading = false
        if waitingToConfirm { confirmRoom() }
    }

    // MARK: Room

    var widthFt: Double? {
        guard let v = Double(widthText.replacingOccurrences(of: ",", with: ".")), v > 0, v <= 1000 else { return nil }
        return v
    }

    var calibration: DiagramCalibration? {
        guard let tl = topLeft, let br = bottomRight, let w = widthFt else { return nil }
        let c = DiagramCalibration(topLeft: tl, bottomRight: br, widthFt: w)
        return c.isValid ? c : nil
    }

    func tapRoom(at pixel: PlanPoint) {
        if topLeft == nil {
            topLeft = pixel
        } else if bottomRight == nil {
            guard pixel.x > topLeft!.x + 10, pixel.y > topLeft!.y + 10 else { return }
            bottomRight = pixel
        }
    }

    func redoCorners() {
        topLeft = nil
        bottomRight = nil
    }

    func confirmRoom() {
        guard let cal = calibration else { return }
        guard let reading else {
            waitingToConfirm = true
            return
        }
        waitingToConfirm = false
        items = DiagramLayoutBuilder.items(from: reading, calibration: cal)
        foundCount = items.filter { $0.type.isTable }.count
        selectedID = nil
        step = .tables
    }

    // MARK: Tables

    var tableCount: Int { items.filter { $0.type.isTable }.count }

    func tapTables(at plan: PlanPoint) {
        let hits = items.filter { $0.footprint.inflated(by: 1).contains(plan) }
            .sorted { $0.size.length * $0.size.width < $1.size.length * $1.size.width }
        if let hit = hits.first {
            selectedID = selectedID == hit.id ? nil : hit.id
            return
        }
        if selectedID != nil {
            selectedID = nil
            return
        }
        guard let room = calibration?.room, room.contains(plan) else { return }
        let label = nextLabel()
        addedCount += 1
        let item = LayoutItem(id: "NEW\(addedCount)", type: .roundTable, label: label, x: plan.x, y: plan.y,
                              diameterFt: 5, seats: DiagramLayoutBuilder.defaultSeats(.roundTable, length: 5))
        items.append(item)
        selectedID = item.id
    }

    private func nextLabel() -> String {
        let used = Set(items.compactMap(\.label))
        var n = (items.compactMap { $0.label.flatMap(Int.init) }.max() ?? 0) + 1
        while used.contains(String(n)) { n += 1 }
        return String(n)
    }

    var selected: LayoutItem? {
        get { items.first { $0.id == selectedID } }
        set {
            guard let newValue, let i = items.firstIndex(where: { $0.id == newValue.id }) else { return }
            items[i] = newValue
        }
    }

    func setType(_ type: ItemType) {
        guard var item = selected, item.type != type else { return }
        let size = item.size
        item.type = type
        switch type {
        case .roundTable:
            item.diameterFt = max(2.5, min(size.length, 8))
            item.lengthFt = nil
            item.widthFt = nil
            item.rotation = nil
        default:
            item.diameterFt = nil
            item.lengthFt = type == .banquetTable ? max(size.length, 6) : max(size.length, 8)
            item.widthFt = type == .banquetTable ? 2.5 : max(size.width, 3)
            item.rotation = item.rotation ?? 0
        }
        item.seats = DiagramLayoutBuilder.defaultSeats(type, length: item.size.length)
        selected = item
    }

    func removeSelected() {
        items.removeAll { $0.id == selectedID }
        selectedID = nil
    }

    // MARK: Points

    func tapPoints(at plan: PlanPoint) {
        guard calibration?.room.contains(plan) == true else { return }
        if pointA == nil { pointA = plan } else if pointB == nil { pointB = plan }
    }

    func redoPoints() {
        pointA = nil
        pointB = nil
    }

    // MARK: Save

    /// Builds and checks the layout. Returns a plain message when something is still missing.
    func makeLayout() -> Result<EventLayout, LayoutError> {
        guard let cal = calibration, let a = pointA, let b = pointB else {
            return .failure(LayoutError("Finish the earlier steps first."))
        }
        // Ids follow labels so they read well in the saved file.
        var ids = Set<String>()
        let finalItems = items.map { item -> LayoutItem in
            var copy = item
            let base: String
            switch item.type {
            case .roundTable, .banquetTable:
                base = "T" + (item.label ?? "").filter { $0.isLetter || $0.isNumber }
            case .stage: base = "STAGE"
            case .bar: base = "BAR"
            case .danceFloor: base = "DANCE"
            }
            var id = base.count > 1 ? base : "\(base)\(ids.count + 1)"
            var k = 2
            while ids.contains(id) { id = "\(base)-\(k)"; k += 1 }
            ids.insert(id)
            copy.id = id
            return copy
        }
        let layout = EventLayout(
            event: EventInfo(name: eventName.trimmingCharacters(in: .whitespaces),
                             room: roomName.trimmingCharacters(in: .whitespaces).isEmpty ? "Main room" : roomName,
                             start: hasDate ? date : nil,
                             guests: Int(guestsText)),
            room: cal.room,
            referencePoints: ReferencePoints(a: ReferencePoint(x: a.x, y: a.y, label: labelA),
                                             b: ReferencePoint(x: b.x, y: b.y, label: labelB)),
            items: finalItems,
            aisles: [])
        do {
            try LayoutLoader.validate(layout)
            return .success(layout)
        } catch let e as LayoutError {
            return .failure(e)
        } catch {
            return .failure(LayoutError("This layout can't be saved."))
        }
    }
}
