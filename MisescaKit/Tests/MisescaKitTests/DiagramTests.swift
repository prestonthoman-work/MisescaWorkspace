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

    /// The bundled sample diagram (also offered in Settings) is the Harbor layout drawn at 14 px
    /// per foot. Found with no help: room corners, then every table, by the 60 in rounds.
    func testReadsBundledSampleDiagram() throws {
        let truth = try LayoutLoader.load(Data(contentsOf: LayoutLoaderTests.resources.appendingPathComponent("harbor-room-gala.json")))
        let image = try loadImage("harbor-diagram.png")
        let corners = try XCTUnwrap(DiagramCorners.detect(in: image))
        let result = try DiagramPipeline.run(image, setup: DiagramSetup(corners: corners, scale: .roundDiameter(5)))
        XCTAssertEqual(result.calibration.widthFt, 90, accuracy: 0.2)
        XCTAssertEqual(result.calibration.depthFt, 70, accuracy: 0.2)
        let score = DiagramAccuracyTests.score("bundled sample", truth: truth, got: result.items)
        XCTAssertEqual(score.found, truth.tables.count)
        XCTAssertEqual(score.extras, 0)
        XCTAssertLessThanOrEqual(score.maxError, 0.15)
        XCTAssertEqual(score.labelsRight, truth.tables.count)
        let gift = result.items.first { $0.type == .banquetTable && $0.center.distance(to: PlanPoint(x: 68, y: 66)) < 1 }
        XCTAssertEqual(gift?.label, "Gift table")
        XCTAssertNotNil(result.items.first { $0.type == .bar }, "bar")
        XCTAssertNotNil(result.items.first { $0.type == .stage }, "stage")
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
