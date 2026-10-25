import Foundation
import Observation
import UIKit
import MisescaKit

/// Steps for turning a diagram image into a layout. Every step ends with the person confirming;
/// nothing found in the image is saved without being looked at.
@MainActor
@Observable
final class DiagramImportModel {
    enum Step { case corners, scale, reading, tables, points, details }
    enum ScaleChoice: Hashable { case rounds, room }

    let source: DiagramSource
    var step: Step = .corners

    // Corners, in source image pixels: top-left, top-right, bottom-right, bottom-left.
    var corners: [PlanPoint] = []
    private(set) var findingCorners = true
    private(set) var tightening = false

    // Scale
    var scaleChoice: ScaleChoice = .rounds
    var roundInches: Double = 60
    var widthText = ""
    var depthText = ""
    var readError: String?

    // What was read, on the straightened image. Plan coordinates map onto it directly.
    private(set) var result: DiagramResult?
    private(set) var straightened: UIImage?
    var items: [LayoutItem] = []
    var guessed: Set<String> = []
    var selectedID: String?
    private(set) var foundCount = 0

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

    @ObservationIgnored private var addedCount = 0

    init(source: DiagramSource) {
        self.source = source
        eventName = source.suggestedName
        let w = Double(source.image.size.width), h = Double(source.image.size.height)
        let inset = 0.06
        corners = [PlanPoint(x: w * inset, y: h * inset), PlanPoint(x: w * (1 - inset), y: h * inset),
                   PlanPoint(x: w * (1 - inset), y: h * (1 - inset)), PlanPoint(x: w * inset, y: h * (1 - inset))]
    }

    /// The image the current step draws on.
    var displayImage: UIImage {
        switch step {
        case .corners, .scale, .reading: return source.image
        default: return straightened ?? source.image
        }
    }

    var calibration: DiagramCalibration? { result?.calibration }

    // MARK: Corners

    func findCorners() async {
        guard let cg = source.image.cgImage else { findingCorners = false; return }
        let found = await Task.detached(priority: .userInitiated) { DiagramCorners.detect(in: cg) }.value
        if let found, found.count == 4 { corners = found }
        findingCorners = false
    }

    func moveCorner(_ index: Int, to p: PlanPoint) {
        let w = Double(source.image.size.width), h = Double(source.image.size.height)
        corners[index] = PlanPoint(x: min(max(0, p.x), w), y: min(max(0, p.y), h))
    }

    /// Snaps the corners onto the walls (or page edges) next to where they were dropped.
    func tightenCorners() async {
        guard let cg = source.image.cgImage else { return }
        tightening = true
        let given = corners
        let tightened = await Task.detached(priority: .userInitiated) { DiagramCorners.refine(given, in: cg) }.value
        // Only take it if nothing moved in the meantime.
        if corners == given { corners = tightened }
        tightening = false
    }

    // MARK: Scale and reading

    var widthFt: Double? { Self.feet(widthText) }
    var depthFt: Double? { Self.feet(depthText) }

    static func feet(_ text: String) -> Double? {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v >= 5, v <= 1000 else { return nil }
        return v
    }

    var canRead: Bool {
        switch scaleChoice {
        case .rounds: return true
        case .room: return widthFt != nil && depthFt != nil
        }
    }

    func read() async {
        guard let cg = source.image.cgImage else { readError = "Couldn't read this image."; return }
        let scale: DiagramSetup.Scale
        switch scaleChoice {
        case .rounds: scale = .roundDiameter(roundInches / 12)
        case .room:
            guard let w = widthFt, let d = depthFt else { return }
            scale = .roomSize(widthFt: w, depthFt: d)
        }
        readError = nil
        step = .reading
        let setup = DiagramSetup(corners: corners, scale: scale)
        do {
            let r = try await Task.detached(priority: .userInitiated) { try DiagramPipeline.run(cg, setup: setup) }.value
            result = r
            straightened = UIImage(cgImage: r.image)
            corners = r.corners
            items = r.items
            guessed = r.guessedLabels
            foundCount = r.items.filter(\.type.isTable).count
            selectedID = nil
            pointA = nil
            pointB = nil
            step = .tables
        } catch DiagramError.noRoundsToSizeFrom {
            readError = DiagramError.noRoundsToSizeFrom.errorDescription
            scaleChoice = .room
            step = .scale
        } catch {
            readError = error.localizedDescription
            step = .scale
        }
    }

    var warnings: [String] { result?.warnings ?? [] }

    // MARK: Tables

    var tableCount: Int { items.filter { $0.type.isTable }.count }
    var guessedCount: Int { items.filter { guessed.contains($0.id) }.count }

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
                              diameterFt: roundInches / 12,
                              seats: DiagramLayoutBuilder.defaultSeats(.roundTable, length: roundInches / 12))
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
            if items[i].label != newValue.label { guessed.remove(newValue.id) }
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
