import Foundation
import CoreGraphics

/// Finds and tightens the four corners that tie a diagram image to the room.
///
/// Corners matter more than anything else for accuracy: on a phone photo, a corner placed nine
/// pixels off moves tables by over half a foot. Rather than trust a fingertip, each side is
/// measured along its length to a fraction of a pixel, fitted with a straight line, and the
/// corners are where those lines meet.
public enum DiagramCorners {
    /// The room's outline, if the image has one: the largest enclosed area, reduced to four corners.
    /// Corners run top-left, top-right, bottom-right, bottom-left.
    public static func detect(in image: CGImage) -> [PlanPoint]? {
        guard let g = RegionTracer.Gray(image) else { return nil }
        let w = g.width, h = g.height
        let ink = RegionTracer.inkMask(g)
        let regions = RegionTracer.regions(of: ink, target: false, width: w, height: h,
                                           minPixels: w * h / 8, maxPixels: w * h)
        guard let room = regions.max(by: { $0.pixels < $1.pixels }) else { return nil }
        var outline: [PlanPoint] = []
        for (y, span) in room.rows {
            outline.append(PlanPoint(x: Double(span.0), y: Double(y)))
            outline.append(PlanPoint(x: Double(span.1), y: Double(y)))
        }
        // A room's corners are its farthest points along the diagonals (in image coordinates).
        outline = outline.map { $0 + PlanPoint(x: 0.5, y: 0.5) }
        guard outline.count >= 4 else { return nil }
        let quad = [outline.min { $0.x + $0.y < $1.x + $1.y }!, outline.max { $0.x - $0.y < $1.x - $1.y }!,
                    outline.max { $0.x + $0.y < $1.x + $1.y }!, outline.min { $0.x - $0.y < $1.x - $1.y }!]
        return refine(quad, in: image)
    }

    /// Tightens rough corners onto the drawn walls (or the page's edges in a photo). Sides with
    /// nothing clear to measure keep the corners as given.
    public static func refine(_ given: [PlanPoint], in image: CGImage) -> [PlanPoint] {
        guard given.count == 4, let g = RegionTracer.Gray(image) else { return given }
        // Measurements run on pixel indices, whose centers sit half a pixel in from image coordinates.
        let half = PlanPoint(x: 0.5, y: 0.5)
        let corners = given.map { $0 - half }
        let center = corners.reduce(PlanPoint(x: 0, y: 0), +) * 0.25
        let reach = max(40, 0.012 * Double(max(g.width, g.height)))
        var lines: [(point: PlanPoint, direction: PlanPoint)?] = []
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            // Wide search first, then measure again closely along the line it found.
            guard let rough = fitSide(from: a, to: b, center: center, gray: g, search: reach) else { lines.append(nil); continue }
            func onto(_ p: PlanPoint) -> PlanPoint { rough.point + rough.direction * (p - rough.point).dot(rough.direction) }
            lines.append(fitSide(from: onto(a), to: onto(b), center: center, gray: g, search: 8) ?? rough)
        }
        var out = corners
        for i in 0..<4 {
            // Corner i sits between side i-1 (into it) and side i (out of it).
            guard let l1 = lines[(i + 3) % 4], let l2 = lines[i],
                  let p = intersect(l1, l2), p.distance(to: corners[i]) < reach * 1.5 else { continue }
            out[i] = p
        }
        return out.map { $0 + half }
    }

    /// Measures where a side's line actually runs, at many points along it, and fits a line.
    /// Every edge crossing at every point is a candidate; the side is the straight line the most
    /// points agree on. A stage or table near the wall covers only part of the side, so it loses.
    static func fitSide(from a: PlanPoint, to b: PlanPoint, center: PlanPoint, gray g: RegionTracer.Gray, search: Double) -> (point: PlanPoint, direction: PlanPoint)? {
        let along = (b - a).normalized
        var normal = PlanPoint(x: -along.y, y: along.x)
        // Point the normal outward, away from the room.
        if (a - center).dot(normal) < 0 { normal = normal * -1 }
        guard a.distance(to: b) > 40 else { return nil }
        for edge in [RegionTracer.Edge.line, .step] {
            // Stay clear of the corners themselves, where the other wall crosses.
            var samples: [[PlanPoint]] = []
            for f in stride(from: 0.08, through: 0.92, by: 0.02) {
                let base = a + (b - a) * f
                let start = base - normal * search
                let found = RegionTracer.edgeCandidates(g, origin: start, direction: normal, from: 0, to: 2 * search, edge: edge)
                if !found.isEmpty { samples.append(found.map { start + normal * $0 }) }
            }
            guard samples.count >= 12, let line = consensusLine(samples, outward: normal) else { continue }
            return line
        }
        return nil
    }

    /// The line through the most sample positions (each position may offer several candidates).
    /// Ties go to the outermost line, since a room's wall is its outer edge.
    static func consensusLine(_ samples: [[PlanPoint]], outward: PlanPoint) -> (point: PlanPoint, direction: PlanPoint)? {
        let tolerance = 1.2
        var best: (count: Int, outward: Double, inliers: [PlanPoint])?
        // Try lines through candidates at well-separated positions.
        let n = samples.count
        for i in 0..<(n / 3) {
            for j in stride(from: n - 1, through: n - n / 3, by: -1) {
                for p in samples[i] {
                    for q in samples[j] {
                        let d = (q - p).normalized
                        let nrm = PlanPoint(x: -d.y, y: d.x)
                        var inliers: [PlanPoint] = []
                        for cands in samples {
                            if let hit = cands.min(by: { abs(($0 - p).dot(nrm)) < abs(($1 - p).dot(nrm)) }),
                               abs((hit - p).dot(nrm)) <= tolerance {
                                inliers.append(hit)
                            }
                        }
                        let out = (p + q).dot(outward) / 2
                        if best == nil || inliers.count > best!.count || (inliers.count == best!.count && out > best!.outward) {
                            best = (inliers.count, out, inliers)
                        }
                    }
                }
            }
        }
        guard let best, best.count >= max(10, n * 6 / 10) else { return nil }
        return fitLine(best.inliers)
    }

    /// Least-squares line through points, dropping the worst fifth (doors, labels on the wall).
    static func fitLine(_ points: [PlanPoint]) -> (point: PlanPoint, direction: PlanPoint)? {
        func fit(_ p: [PlanPoint]) -> (PlanPoint, PlanPoint)? {
            guard p.count >= 2 else { return nil }
            let c = p.reduce(PlanPoint(x: 0, y: 0), +) * (1 / Double(p.count))
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for q in p {
                let d = q - c
                sxx += d.x * d.x; syy += d.y * d.y; sxy += d.x * d.y
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            return (c, PlanPoint(x: cos(angle), y: sin(angle)))
        }
        guard let first = fit(points) else { return nil }
        let n = PlanPoint(x: -first.1.y, y: first.1.x)
        let residuals = points.map { abs(($0 - first.0).dot(n)) }
        let cutoff = residuals.sorted()[Int(Double(residuals.count) * 0.8)]
        let kept = zip(points, residuals).filter { $0.1 <= cutoff }.map(\.0)
        guard let second = fit(kept) else { return first }
        // A wall is straight; if what was measured isn't, don't trust it.
        let n2 = PlanPoint(x: -second.1.y, y: second.1.x)
        let spread = kept.map { abs(($0 - second.0).dot(n2)) }.max() ?? 0
        return spread < 2.5 ? second : nil
    }

    static func intersect(_ l1: (point: PlanPoint, direction: PlanPoint), _ l2: (point: PlanPoint, direction: PlanPoint)) -> PlanPoint? {
        let d1 = l1.direction, d2 = l2.direction
        let den = d1.x * d2.y - d1.y * d2.x
        guard abs(den) > 1e-6 else { return nil }
        let diff = l2.point - l1.point
        let t = (diff.x * d2.y - diff.y * d2.x) / den
        return l1.point + d1 * t
    }

    /// Top-left, top-right, bottom-right, bottom-left.
    public static func order(_ q: [PlanPoint]) -> [PlanPoint] {
        guard q.count == 4 else { return q }
        let tl = q.min { $0.x + $0.y < $1.x + $1.y }!
        let br = q.max { $0.x + $0.y < $1.x + $1.y }!
        let rest = q.filter { $0 != tl && $0 != br }
        guard rest.count == 2 else { return q }
        let tr = rest.max { $0.x - $0.y < $1.x - $1.y }!
        let bl = rest.min { $0.x - $0.y < $1.x - $1.y }!
        return [tl, tr, br, bl]
    }
}
