import XCTest
import CoreGraphics
import ImageIO
@testable import MisescaKit

final class DiagramTests: XCTestCase {
    func loadImage(_ name: String) throws -> CGImage {
        let url = LayoutLoaderTests.resources.appendingPathComponent(name)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// The bundled sample diagram is the Harbor layout drawn at 14 px per foot,
    /// with the room's corners at (60, 110) and (1320, 1090).
    func testReadsHarborDiagram() throws {
        let truth = try LayoutLoader.load(Data(contentsOf: LayoutLoaderTests.resources.appendingPathComponent("harbor-room-gala.json")))
        let reading = try DiagramReader.read(loadImage("harbor-diagram.png"))
        let cal = DiagramCalibration(topLeft: PlanPoint(x: 60, y: 110), bottomRight: PlanPoint(x: 1320, y: 1090), widthFt: 90)
        XCTAssertEqual(cal.depthFt, 70, accuracy: 0.01)

        let items = DiagramLayoutBuilder.items(from: reading, calibration: cal)
        let rounds = items.filter { $0.type == .roundTable }
        XCTAssertEqual(rounds.count, 30, "found \(items.map { "\($0.label ?? "?")@\(Int($0.x)),\(Int($0.y))" })")

        var labelled = 0
        for t in truth.items where t.type == .roundTable {
            guard let match = rounds.min(by: { $0.center.distance(to: t.center) < $1.center.distance(to: t.center) }) else { continue }
            XCTAssertLessThan(match.center.distance(to: t.center), 0.5, "\(t.id)")
            XCTAssertEqual(match.diameterFt ?? 0, 5, accuracy: 0.5)
            if match.label == t.label { labelled += 1 }
        }
        XCTAssertEqual(labelled, 30, "table numbers read correctly")

        let gift = items.first { $0.type == .banquetTable && $0.center.distance(to: PlanPoint(x: 68, y: 66)) < 1 }
        XCTAssertEqual(gift?.label, "Gift table")
        XCTAssertNotNil(items.first { $0.type == .bar }, "bar")
        XCTAssertNotNil(items.first { $0.type == .stage }, "stage")
    }

    func testReadsLowResolutionExport() throws {
        // The same diagram at 60% size, like a compressed export or a screenshot.
        let full = try loadImage("harbor-diagram.png")
        let w = Int(Double(full.width) * 0.6), h = Int(Double(full.height) * 0.6)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        let small = try XCTUnwrap(ctx.makeImage())

        let reading = try DiagramReader.read(small)
        let cal = DiagramCalibration(topLeft: PlanPoint(x: 36, y: 66), bottomRight: PlanPoint(x: 792, y: 654), widthFt: 90)
        let items = DiagramLayoutBuilder.items(from: reading, calibration: cal)
        let rounds = items.filter { $0.type == .roundTable }
        XCTAssertEqual(rounds.count, 30)
        let truth = try LayoutLoader.load(Data(contentsOf: LayoutLoaderTests.resources.appendingPathComponent("harbor-room-gala.json")))
        let labelled = truth.items.filter { t in
            t.type == .roundTable && rounds.contains { $0.label == t.label && $0.center.distance(to: t.center) < 0.75 }
        }.count
        // Currently 26 of 30. The review screen exists to fix the rest.
        XCTAssertGreaterThanOrEqual(labelled, 25, "table numbers read correctly at low resolution")
    }

    func testClassifiesCircleAndRotatedRectangle() {
        let circle = (0..<64).map { i -> PlanPoint in
            let a = Double(i) / 64 * 2 * .pi
            return PlanPoint(x: 100 + 30 * cos(a), y: 50 + 30 * sin(a))
        }
        let c = ShapeClassifier.classify(circle)
        XCTAssertEqual(c?.kind, .circle)
        XCTAssertEqual(c?.length ?? 0, 60, accuracy: 1)

        let rect = Footprint(center: PlanPoint(x: 200, y: 200), length: 80, width: 25, rotationDegrees: 30).corners
        let r = ShapeClassifier.classify(rect)
        XCTAssertEqual(r?.kind, .rectangle)
        XCTAssertEqual(r?.length ?? 0, 80, accuracy: 0.5)
        XCTAssertEqual(r?.width ?? 0, 25, accuracy: 0.5)
        XCTAssertEqual(r?.rotationDegrees ?? 0, 30, accuracy: 0.5)
    }

    func testCalibration() {
        let cal = DiagramCalibration(topLeft: PlanPoint(x: 10, y: 20), bottomRight: PlanPoint(x: 310, y: 220), widthFt: 60)
        XCTAssertEqual(cal.feetPerPixel, 0.2, accuracy: 1e-9)
        XCTAssertEqual(cal.depthFt, 40, accuracy: 1e-9)
        let p = cal.plan(PlanPoint(x: 160, y: 120))
        XCTAssertEqual(p.x, 30, accuracy: 1e-9)
        XCTAssertEqual(p.y, 20, accuracy: 1e-9)
        XCTAssertEqual(cal.pixel(p), PlanPoint(x: 160, y: 120))
    }
}
