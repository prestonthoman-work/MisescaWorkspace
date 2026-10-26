import XCTest
import simd
@testable import MisescaKit

final class LayoutLoaderTests: XCTestCase {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Misesca/Resources")

    func testBundledSamplesLoad() throws {
        let harbor = try LayoutLoader.load(Data(contentsOf: Self.resources.appendingPathComponent("harbor-room-gala.json")))
        XCTAssertEqual(harbor.event.name, "Harbor Room Gala")
        XCTAssertEqual(harbor.counts.rounds, 30)
        XCTAssertEqual(harbor.counts.seats, 240)
        XCTAssertEqual(harbor.aisles.count, 2)

        let demo = try LayoutLoader.load(Data(contentsOf: Self.resources.appendingPathComponent("demo-room.json")))
        XCTAssertEqual(demo.tables.count, 7)
    }

    func testSampleTablesDoNotOverlap() throws {
        for file in ["harbor-room-gala.json", "demo-room.json"] {
            let layout = try LayoutLoader.load(Data(contentsOf: Self.resources.appendingPathComponent(file)))
            for (i, a) in layout.items.enumerated() {
                for b in layout.items[(i + 1)...] {
                    XCTAssertFalse(a.footprint.corners.contains(where: b.footprint.contains)
                                   || b.footprint.corners.contains(where: a.footprint.contains),
                                   "\(file): \(a.id) overlaps \(b.id)")
                }
            }
        }
    }

    func testMissingKeyIsExplained() {
        let json = #"{"event":{"name":"X","room":"R"},"reference_points":{},"items":[]}"#
        XCTAssertThrowsError(try LayoutLoader.load(Data(json.utf8))) { e in
            XCTAssertEqual((e as? LayoutError)?.message, "The file is missing \"room\".")
        }
    }

    func testUnknownTypeIsExplained() {
        let json = """
        {"event":{"name":"X","room":"R"},"room":{"width_ft":30,"depth_ft":20},
         "reference_points":{"A":{"x":5,"y":5,"label":"a"},"B":{"x":25,"y":5,"label":"b"}},
         "items":[{"id":"T1","type":"sofa","x":10,"y":10}]}
        """
        XCTAssertThrowsError(try LayoutLoader.load(Data(json.utf8))) { e in
            XCTAssertTrue((e as? LayoutError)?.message.contains("isn't a known item type") ?? false, "\(e)")
        }
    }

    func testRoundWithoutDiameterFails() {
        let json = """
        {"event":{"name":"X","room":"R"},"room":{"width_ft":30,"depth_ft":20},
         "reference_points":{"A":{"x":5,"y":5,"label":"a"},"B":{"x":25,"y":5,"label":"b"}},
         "items":[{"id":"T1","type":"round_table","x":10,"y":10}]}
        """
        XCTAssertThrowsError(try LayoutLoader.load(Data(json.utf8))) { e in
            XCTAssertEqual((e as? LayoutError)?.message, "Item \"T1\" is a round table and needs diameter_ft.")
        }
    }

    func testOvalTableLoads() throws {
        let json = """
        {"event":{"name":"X","room":"R"},"room":{"width_ft":30,"depth_ft":20},
         "reference_points":{"A":{"x":5,"y":5,"label":"a"},"B":{"x":25,"y":5,"label":"b"}},
         "items":[{"id":"T1","type":"oval_table","x":10,"y":10,"length_ft":8,"width_ft":4,"rotation":30}]}
        """
        let layout = try LayoutLoader.load(Data(json.utf8))
        let oval = try XCTUnwrap(layout.items.first)
        XCTAssertEqual(oval.type, .ovalTable)
        XCTAssertTrue(oval.type.isTable)
        XCTAssertEqual(oval.size.length, 8)
        XCTAssertEqual(oval.size.width, 4)
        XCTAssertEqual(layout.counts.ovalTables, 1)
        XCTAssertEqual(DiagramLayoutBuilder.defaultSeats(.ovalTable, length: 8, width: 4), 9)
    }

    func testNotJSON() {
        XCTAssertThrowsError(try LayoutLoader.load(Data("hello".utf8))) { e in
            XCTAssertEqual((e as? LayoutError)?.message, "This isn't a Misesca layout file. Layout files end in .json, like the samples.")
        }
    }

    func testRoundTripThroughStorageEncoding() throws {
        let layout = try LayoutLoader.load(Data(contentsOf: Self.resources.appendingPathComponent("harbor-room-gala.json")))
        let data = try LayoutLoader.encoder().encode(layout)
        XCTAssertEqual(try LayoutLoader.decoder().decode(EventLayout.self, from: data), layout)
    }
}

final class AlignmentTests: XCTestCase {
    func testRoundTripAndScale() {
        let a = PlanPoint(x: 45, y: 12), b = PlanPoint(x: 45, y: 68)
        // Real taps: B is 56 ft (17.0688 m) from A, rotated an arbitrary 37 degrees.
        let len = Units.meters(56)
        let ang = 37.0 * .pi / 180
        let wa = SIMD3(1.0, -1.4, 2.0)
        let wb = wa + SIMD3(cos(ang) * len, 0, sin(ang) * len)
        let al = PlanAlignment(planA: a, planB: b, worldA: wa, worldB: wb)

        XCTAssertEqual(simd_distance(al.world(b), wb), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(al.world(a), wa), 0, accuracy: 1e-9)

        let p = PlanPoint(x: 8, y: 17)
        let back = al.plan(al.world(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)

        // 1:1 scale: two plan points 10 ft apart are 3.048 m apart in the world.
        let d = simd_distance(al.world(PlanPoint(x: 0, y: 0)), al.world(PlanPoint(x: 10, y: 0)))
        XCTAssertEqual(d, 3.048, accuracy: 1e-9)
        XCTAssertTrue(al.distanceCheck.isAcceptable)
    }

    func testHandednessIsPreserved() {
        // Plan x maps to world x, plan y (down the page) maps to world z with no rotation.
        let al = PlanAlignment(planA: PlanPoint(x: 0, y: 0), planB: PlanPoint(x: 10, y: 0),
                               worldA: SIMD3(0, 0, 0), worldB: SIMD3(3.048, 0, 0))
        let w = al.world(PlanPoint(x: 0, y: 10))
        XCTAssertEqual(w.x, 0, accuracy: 1e-9)
        XCTAssertEqual(w.z, 3.048, accuracy: 1e-9)
    }

    func testDistanceWarning() {
        let al = PlanAlignment(planA: PlanPoint(x: 45, y: 12), planB: PlanPoint(x: 45, y: 68),
                               worldA: SIMD3(0, 0, 0), worldB: SIMD3(0, 0, Units.meters(64)))
        XCTAssertFalse(al.distanceCheck.isAcceptable)
        XCTAssertEqual(al.distanceCheck.message,
                       "Your two points are 8 ft farther apart than the plan says. Check them and try again.")
    }

    func testRotationConversion() {
        let al = PlanAlignment(planA: PlanPoint(x: 0, y: 0), planB: PlanPoint(x: 10, y: 0),
                               worldA: SIMD3(0, 0, 0), worldB: SIMD3(0, 0, 3.048))
        // Plan x points along world +z here, so a world heading along +z is plan rotation 0.
        XCTAssertEqual(al.planRotationDegrees(worldHeading: .pi / 2), 0, accuracy: 1e-9)
    }
}

final class MiseCheckTests: XCTestCase {
    var layout: EventLayout!

    override func setUpWithError() throws {
        layout = try LayoutLoader.load(Data(contentsOf: LayoutLoaderTests.resources.appendingPathComponent("harbor-room-gala.json")))
    }

    func scanned(movedID: String? = nil, by offset: PlanPoint = PlanPoint(x: 0, y: 0), drop: Set<String> = []) -> [DetectedObject] {
        layout.tables.filter { !drop.contains($0.id) }.map { t in
            var f = t.footprint
            if t.id == movedID { f.center = f.center + offset }
            // Small scan noise on every table, well inside tolerance.
            f.center = f.center + PlanPoint(x: 0.2, y: -0.15)
            return DetectedObject(footprint: f, isTable: true)
        }
    }

    func testCleanRoom() {
        let r = ReportBuilder.roomScan(layout: layout, detected: scanned(), settings: CheckSettings())
        XCTAssertEqual(r.count(.enPlace), 31)
        XCTAssertTrue(r.isClean, r.summary)
        XCTAssertEqual(r.summary, "31 en place.")
    }

    func testMovingOneTableThreeFeetFlagsExactlyThatTable() {
        // Table 14 moved 3 ft toward the stage (up the page).
        let r = ReportBuilder.roomScan(layout: layout, detected: scanned(movedID: "T14", by: PlanPoint(x: 0, y: -3)), settings: CheckSettings())
        let off = r.tables.filter { $0.status == .off }
        XCTAssertEqual(off.map(\.itemID), ["T14"])
        XCTAssertEqual(r.count(.missing), 0)
        XCTAssertTrue(r.extras.isEmpty)
        XCTAssertEqual(Wording(layout: layout).message(for: off[0]), "Table 14 is 3 ft toward the stage.")
        XCTAssertEqual(r.summary, "30 en place, 1 off.")
    }

    func testMissingAndExtra() {
        var detected = scanned(drop: ["T3"])
        detected.append(DetectedObject(footprint: Footprint(center: PlanPoint(x: 35, y: 45), length: 5, width: 5, rotationDegrees: 0), isTable: true))
        let r = ReportBuilder.roomScan(layout: layout, detected: detected, settings: CheckSettings())
        XCTAssertEqual(r.tables.first { $0.itemID == "T3" }?.status, .missing)
        XCTAssertEqual(r.extras.count, 1)
        XCTAssertEqual(r.summary, "30 en place, 1 missing, 1 extra.")
    }

    func testTableOnStageIsIgnored() {
        var detected = scanned()
        detected.append(DetectedObject(footprint: Footprint(center: PlanPoint(x: 45, y: 6), length: 4, width: 2, rotationDegrees: 0), isTable: true))
        let r = ReportBuilder.roomScan(layout: layout, detected: detected, settings: CheckSettings())
        XCTAssertTrue(r.extras.isEmpty)
    }

    func testAisleTooNarrow() {
        var detected = scanned()
        // A cart parked in the center aisle leaves 4 ft of the planned 6.
        detected.append(DetectedObject(footprint: Footprint(center: PlanPoint(x: 44, y: 50), length: 2, width: 4, rotationDegrees: 0), isTable: false))
        detected.append(DetectedObject(footprint: Footprint(center: PlanPoint(x: 50, y: 50), length: 2, width: 4, rotationDegrees: 0), isTable: false))
        let r = ReportBuilder.roomScan(layout: layout, detected: detected, settings: CheckSettings())
        let center = r.aisles.first { $0.aisleID == "AISLE-MAIN" }!
        XCTAssertEqual(center.measuredFt, 0, accuracy: 1e-9) // the first box sits on the center line
        XCTAssertFalse(center.passes)
        XCTAssertEqual(Wording(layout: layout).message(for: center), "Center aisle is blocked. Plan calls for 6 ft.")
    }

    func testAisleWidthMeasurement() {
        let aisle = Aisle(id: "A", label: "Aisle by Exit B", from: PlanPoint(x: 10, y: 0), to: PlanPoint(x: 10, y: 20), minWidthFt: 6)
        let room = RoomSize(widthFt: 20, depthFt: 20)
        let left = Footprint(center: PlanPoint(x: 7, y: 10), length: 2, width: 2, rotationDegrees: 0)  // edge at x = 8
        let right = Footprint(center: PlanPoint(x: 13, y: 10), length: 2, width: 2, rotationDegrees: 0) // edge at x = 12
        let r = AisleChecker.measure(aisle, obstacles: [left, right], room: room)
        XCTAssertEqual(r.measuredFt, 4, accuracy: 1e-9)
        XCTAssertEqual(Wording(layout: layout).message(for: r), "A is 4 ft. Plan calls for 6 ft.")
    }

    func testRotatedObstacle() {
        let f = Footprint(center: PlanPoint(x: 0, y: 0), length: 4, width: 2, rotationDegrees: 90)
        XCTAssertTrue(f.contains(PlanPoint(x: 0, y: 1.9)))
        XCTAssertFalse(f.contains(PlanPoint(x: 1.9, y: 0)))
        XCTAssertEqual(f.rayEntry(from: PlanPoint(x: 0, y: 10), direction: PlanPoint(x: 0, y: -1))!, 8, accuracy: 1e-9)
    }

    func testPointCheck() {
        let settings = CheckSettings(toleranceInches: 12)
        let checks = [PlanPoint(x: 8.3, y: 16.2), PlanPoint(x: 20.5, y: 16), PlanPoint(x: 8, y: 16)]
        let r = ReportBuilder.pointCheck(layout: layout, checks: checks, settings: settings)
        XCTAssertEqual(r.tables.first { $0.itemID == "T1" }?.status, .enPlace)
        XCTAssertEqual(r.tables.first { $0.itemID == "T2" }?.status, .off)
        XCTAssertEqual(r.count(.notChecked), 29)
        XCTAssertFalse(r.isClean)
    }

    func testSampleAislesStayClearWithChairs() {
        // A real scan sees chairs around every round, roughly 1.5 ft past the table edge.
        // The sample layout should still pass its own aisle minimums when set correctly.
        var detected = scanned()
        for t in layout.tables where t.type == .roundTable {
            detected.append(DetectedObject(footprint: t.footprint.inflated(by: 1.5), isTable: false))
        }
        detected.append(DetectedObject(footprint: layout.item(id: "BAR1")!.footprint, isTable: false))
        detected.append(DetectedObject(footprint: layout.item(id: "GIFT")!.footprint, isTable: false))
        let r = ReportBuilder.roomScan(layout: layout, detected: detected, settings: CheckSettings())
        for a in r.aisles {
            XCTAssertTrue(a.passes, "\(a.aisleID) measured \(a.measuredFt) ft, needs \(a.requiredFt)")
        }
    }

    func pairLayout() -> EventLayout {
        EventLayout(
            event: EventInfo(name: "Pair", room: "R", start: nil, guests: nil),
            room: RoomSize(widthFt: 40, depthFt: 30),
            referencePoints: ReferencePoints(a: ReferencePoint(x: 20, y: 2, label: "Front, center"),
                                             b: ReferencePoint(x: 20, y: 28, label: "Door, center")),
            items: [
                LayoutItem(id: "T1", type: .banquetTable, label: "1", x: 10, y: 10, lengthFt: 6, widthFt: 2.5),
                LayoutItem(id: "T2", type: .banquetTable, label: "2", x: 16, y: 10, lengthFt: 6, widthFt: 2.5),
                LayoutItem(id: "T3", type: .banquetTable, label: "3", x: 30, y: 10, lengthFt: 6, widthFt: 2.5)
            ],
            aisles: [])
    }

    func testTablesPushedTogetherCountAsBoth() {
        let pair = pairLayout()
        let merged = DetectedObject(footprint: Footprint(center: PlanPoint(x: 13, y: 10), length: 12, width: 2.5, rotationDegrees: 0), isTable: true)
        let single = DetectedObject(footprint: pair.item(id: "T3")!.footprint, isTable: true)
        let r = ReportBuilder.roomScan(layout: pair, detected: [merged, single], settings: CheckSettings())
        XCTAssertEqual(r.count(.enPlace), 3, r.summary)
        XCTAssertTrue(r.extras.isEmpty)
    }

    func testPushedTogetherPairOffTogether() {
        let pair = pairLayout()
        let merged = DetectedObject(footprint: Footprint(center: PlanPoint(x: 13, y: 12), length: 12, width: 2.5, rotationDegrees: 0), isTable: true)
        let r = ReportBuilder.roomScan(layout: pair, detected: [merged], settings: CheckSettings())
        XCTAssertEqual(r.tables.filter { $0.status == .off }.map(\.itemID), ["T1", "T2"])
        XCTAssertEqual(r.tables.first { $0.itemID == "T3" }?.status, .missing)
        XCTAssertEqual(Wording(layout: pair).message(for: r.tables[0]), "Table 1 is 2 ft toward the door.")
    }

    func testSingleBigTableIsNotSplit() {
        // A detection covering one plan table stays one table, even if it's larger.
        let pair = pairLayout()
        let big = DetectedObject(footprint: Footprint(center: PlanPoint(x: 30, y: 10), length: 8, width: 3, rotationDegrees: 0), isTable: true)
        let r = ReportBuilder.roomScan(layout: pair, detected: [big], settings: CheckSettings())
        XCTAssertEqual(r.tables.first { $0.itemID == "T3" }?.status, .enPlace)
        XCTAssertEqual(r.count(.missing), 2)
    }

    func testUnmark() {
        var e = EventRecord(layout: layout)
        e.markPlaced("T1"); e.markPlaced("T2"); e.markPlaced("T3")
        e.unmark("T2")
        XCTAssertEqual(e.placed, ["T1", "T3"])
        XCTAssertEqual(e.undoLastMark(), "T3")
    }

    func testDirections() {
        let w = Wording(layout: layout)
        XCTAssertEqual(w.direction(of: PlanPoint(x: 0, y: 3)), "toward the main entrance")
        // Facing the stage (up the page), positive x is to the right.
        XCTAssertEqual(w.direction(of: PlanPoint(x: 2, y: 0)), "to the right, facing the stage")
        XCTAssertEqual(w.direction(of: PlanPoint(x: -2, y: -2)), "toward the stage and to the left")
    }

    func testDistanceWording() {
        XCTAssertEqual(Units.describe(feet: 0.7), "8 in")
        XCTAssertEqual(Units.describe(feet: 3.1), "3 ft")
        XCTAssertEqual(Units.describe(feet: 3.4), "3.5 ft")
    }

    func testEventStatus() {
        var e = EventRecord(layout: layout)
        XCTAssertEqual(e.status, .notStarted)
        e.markPlaced("T1")
        XCTAssertEqual(e.status, .setting)
        for item in layout.items { e.markPlaced(item.id) }
        XCTAssertEqual(e.status, .enPlace)
        XCTAssertEqual(e.undoLastMark(), "DANCE")
        XCTAssertEqual(e.status, .setting)
        e.lastReport = ReportBuilder.roomScan(layout: layout, detected: scanned(drop: ["T1"]), settings: CheckSettings())
        XCTAssertEqual(e.status, .needsAttention)
    }
}
