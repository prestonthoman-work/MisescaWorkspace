import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MisescaKit

/// Runs the reader over every image in $DIAGRAM_DIR and writes an overlay of what it found next to each.
/// Skipped unless DIAGRAM_DIR is set; used to check real-world diagrams by eye.
final class DiagramProbe: XCTestCase {
    func testProbeDirectory() throws {
        guard let dir = ProcessInfo.processInfo.environment["DIAGRAM_DIR"] else { throw XCTSkip("DIAGRAM_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.filter { !$0.hasPrefix("overlay-") }.sorted()
        for f in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let t0 = Date()
            let corners = [PlanPoint(x: 0, y: 0), PlanPoint(x: Double(img.width), y: 0),
                           PlanPoint(x: Double(img.width), y: Double(img.height)), PlanPoint(x: 0, y: Double(img.height))]
            do {
                var result: DiagramResult
                do {
                    result = try DiagramPipeline.run(img, setup: DiagramSetup(corners: corners, scale: .roundDiameter(5), refineCorners: false))
                } catch DiagramError.noRoundsToSizeFrom {
                    // No rounds: show what's found at a stand-in scale of 1 ft per 10 px.
                    result = try DiagramPipeline.run(img, setup: DiagramSetup(corners: corners, scale: .roomSize(widthFt: Double(img.width) / 10, depthFt: Double(img.height) / 10), refineCorners: false))
                }
                let dt = Date().timeIntervalSince(t0)
                let items = result.items
                let rounds = items.filter { $0.type == .roundTable }
                print("PROBE \(f) time=\(String(format: "%.2f", dt))s ftPerPx=\(String(format: "%.4f", result.calibration.feetPerPixel)) room=\(Int(result.calibration.widthFt))x\(Int(result.calibration.depthFt))ft rounds=\(rounds.count) banquet=\(items.filter { $0.type == .banquetTable }.count) other=\(items.filter { !$0.type.isTable }.map { $0.label ?? "?" }) diameters=\(Dictionary(grouping: rounds.compactMap(\.diameterFt), by: { $0 }).mapValues(\.count)) labels=\(items.compactMap(\.label).prefix(40))")
                for d in items where d.type == .danceFloor {
                    print(String(format: "PROBE   dance floor measures %.2f x %.2f ft", d.size.length, d.size.width))
                }
                if !result.warnings.isEmpty { print("PROBE   warning: \(result.warnings)") }
                try writeOverlay(result.image, items: items, cal: result.calibration, to: URL(fileURLWithPath: dir).appendingPathComponent("overlay-\(f).png"))
            } catch {
                print("PROBE \(f) error: \(error.localizedDescription)")
            }
        }
    }

    func writeOverlay(_ img: CGImage, items: [LayoutItem], cal: DiagramCalibration, to url: URL) throws {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.setLineWidth(3)
        for item in items {
            let pts = item.footprint.corners.map { cal.pixel($0) }
            if item.type == .roundTable {
                let c = cal.pixel(item.center); let r = (item.diameterFt ?? 0) / 2 / cal.feetPerPixel
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            } else {
                ctx.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y) }); ctx.closePath(); ctx.strokePath()
            }
            let c = cal.pixel(item.center)
            ctx.fill(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }
}
