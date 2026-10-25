import Foundation
import CoreGraphics

/// Finds table shapes in a diagram by measuring enclosed regions rather than tracing lines.
///
/// A table drawn as an outline leaves a clean region inside it even when chairs touch the
/// outline from outside, and a filled table is a solid region of ink. Each region's shape is
/// measured from its moments, which tells circles, rectangles at any angle, and ellipses apart.
public enum RegionTracer {
    /// One grayscale image, row by row from the top.
    struct Gray {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            pixels = [UInt8](repeating: 255, count: width * height)
            let ok: Bool = pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if !ok { return nil }
        }
    }

    /// Ink is any pixel clearly darker than its neighborhood, so faint gray lines on a gray
    /// floor count as well as black lines on white. Thin gaps are closed by growing ink one pixel.
    static let growPixels = 2

    static func inkMask(_ g: Gray) -> [Bool] {
        let w = g.width, h = g.height
        // Photos carry sensor noise that would read as specks of ink and break up table insides.
        // Smooth over 3x3 first, and set the bar relative to the noise that's left.
        var smooth = [Int](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < w else { continue }
                        sum += Int(g.pixels[yy * w + xx]); n += 1
                    }
                }
                smooth[y * w + x] = sum / n
            }
        }
        // Noise: median difference between neighbors, sampled across the image.
        var diffs: [Int] = []
        diffs.reserveCapacity(w * h / 16)
        for y in stride(from: 1, to: h, by: 4) {
            for x in stride(from: 1, to: w - 1, by: 4) {
                diffs.append(abs(smooth[y * w + x] - smooth[y * w + x - 1]))
            }
        }
        diffs.sort()
        let sigma = diffs.isEmpty ? 0 : Double(diffs[diffs.count / 2]) * 1.4826 / 2.0.squareRoot()
        let bar = max(10, Int((sigma * 5).rounded()))

        // Integral image for fast local means.
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += smooth[y * w + x]
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        // Paper brightness nearby: the brightest 16-pixel block within a wide neighborhood.
        // Inside a large filled table the local mean is the fill itself, so the mean test alone
        // would see only its rim; anything well below the paper is ink whatever surrounds it.
        let block = 16
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var blockMax = [Int](repeating: 0, count: bw * bh)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / block) * bw + x / block
                blockMax[i] = max(blockMax[i], smooth[y * w + x])
            }
        }
        let reach = max(2, min(w, h) / 30 / block)
        var paper = [Int](repeating: 255, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var m = 0
                for yy in max(0, by - reach)...min(bh - 1, by + reach) {
                    for xx in max(0, bx - reach)...min(bw - 1, bx + reach) { m = max(m, blockMax[yy * bw + xx]) }
                }
                paper[by * bw + bx] = m
            }
        }

        let r = max(8, min(w, h) / 60)
        // Two levels: clearly dark pixels are ink; faintly dark pixels are ink only where they
        // connect to clearly dark ones. A faint outline stays continuous; scattered noise doesn't.
        var ink = [Bool](repeating: false, count: w * h)
        var weak = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        let weakBar = max(6, bar / 2)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = sum / ((x1 - x0) * (y1 - y0))
                let v = smooth[y * w + x]
                let bright = paper[(y / block) * bw + x / block]
                if v < mean - bar || v * 10 < bright * 6 {
                    ink[y * w + x] = true
                    stack.append(y * w + x)
                } else if v < mean - weakBar {
                    weak[y * w + x] = true
                }
            }
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let j = yy * w + xx
                    if weak[j] && !ink[j] {
                        ink[j] = true
                        stack.append(j)
                    }
                }
            }
        }
        // Grow ink two pixels to seal gaps where a faint or blurred outline fades out;
        // otherwise a table's inside leaks into the floor and the table is missed.
        var grown = ink
        for _ in 0..<growPixels {
            let current = grown
            for y in 0..<h {
                for x in 0..<w where current[y * w + x] {
                    if x > 0 { grown[y * w + x - 1] = true }
                    if x < w - 1 { grown[y * w + x + 1] = true }
                    if y > 0 { grown[(y - 1) * w + x] = true }
                    if y < h - 1 { grown[(y + 1) * w + x] = true }
                }
            }
        }
        return grown
    }

    /// Per-region running totals, collected from horizontal runs of pixels.
    struct RegionStats {
        var pixels = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var touchesEdge = false
        /// Leftmost and rightmost pixel of each row, for the filled (hole-free) shape.
        var rows: [Int: (Int, Int)] = [:]
    }

    /// Connected regions of `target` pixels (4-connected), labelled with union-find over runs.
    static func regions(of mask: [Bool], target: Bool, width w: Int, height h: Int, minPixels: Int, maxPixels: Int) -> [RegionStats] {
        var parent: [Int] = []
        func find(_ a: Int) -> Int {
            var a = a
            while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }
            return a
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Runs: (y, x0, x1, label)
        var runs: [(y: Int, x0: Int, x1: Int, label: Int)] = []
        var prevRow: [Int] = [] // indices into runs for the previous row
        for y in 0..<h {
            var row: [Int] = []
            var x = 0
            while x < w {
                guard mask[y * w + x] == target else { x += 1; continue }
                let x0 = x
                while x < w, mask[y * w + x] == target { x += 1 }
                let label = parent.count
                parent.append(label)
                runs.append((y, x0, x - 1, label))
                row.append(runs.count - 1)
            }
            // Join with overlapping runs above.
            var j = 0
            for i in row {
                let r = runs[i]
                while j < prevRow.count, runs[prevRow[j]].x1 < r.x0 { j += 1 }
                var k = j
                while k < prevRow.count, runs[prevRow[k]].x0 <= r.x1 {
                    union(r.label, runs[prevRow[k]].label)
                    k += 1
                }
            }
            prevRow = row
        }

        var stats: [Int: RegionStats] = [:]
        for r in runs {
            let root = find(r.label)
            var s = stats[root] ?? RegionStats()
            s.pixels += r.x1 - r.x0 + 1
            s.minX = min(s.minX, r.x0); s.maxX = max(s.maxX, r.x1)
            s.minY = min(s.minY, r.y); s.maxY = max(s.maxY, r.y)
            if r.x0 == 0 || r.x1 == w - 1 || r.y == 0 || r.y == h - 1 { s.touchesEdge = true }
            if let existing = s.rows[r.y] {
                s.rows[r.y] = (min(existing.0, r.x0), max(existing.1, r.x1))
            } else {
                s.rows[r.y] = (r.x0, r.x1)
            }
            stats[root] = s
        }
        return stats.values.filter { !$0.touchesEdge && $0.pixels >= minPixels && $0.pixels <= maxPixels }
    }

    /// Shape of a region from its filled row spans: centroid, principal axes, and fit tests.
    static func shape(of s: RegionStats, inflate: Double) -> DiagramShape? {
        var area = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for (y, span) in s.rows {
            // Treat each row as a strip of pixel centers from span.0 to span.1.
            let a = Double(span.0) - 0.5, b = Double(span.1) + 0.5
            let len = b - a
            let yc = Double(y)
            area += len
            sx += (a + b) / 2 * len
            sy += yc * len
            sxx += (b * b * b - a * a * a) / 3
            syy += yc * yc * len + len / 12
            sxy += yc * (a + b) / 2 * len
        }
        guard area > 0 else { return nil }
        // Holes (like a table number) don't change the filled shape, but a region that is
        // mostly holes is a ring or a frame, not a table.
        guard Double(s.pixels) / area > 0.55 else { return nil }

        let cx = sx / area, cy = sy / area
        let vxx = sxx / area - cx * cx, vyy = syy / area - cy * cy, vxy = sxy / area - cx * cy
        let tr = vxx + vyy, det = vxx * vyy - vxy * vxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-9)
        let center = PlanPoint(x: cx, y: cy)

        let angle = 0.5 * atan2(2 * vxy, vxx - vyy)
        let cosA = cos(angle), sinA = sin(angle)

        // Ellipse (circle) model: semi-axes 2*sqrt(lambda). Rectangle model: sides sqrt(12*lambda).
        // A rectangle fits the ellipse area test to within about 5% and the reverse is also true,
        // so compare both fits and check the outline: a rectangle's corners stick out of the
        // matching ellipse, and an ellipse's outline falls short of the matching rectangle's corners.
        let a = 2 * l1.squareRoot(), b = 2 * l2.squareRoot()
        let length = (12 * l1).squareRoot(), width = (12 * l2).squareRoot()
        let ellipseError = abs(area / (.pi * a * b) - 1)
        let rectError = abs(area / (length * width) - 1)

        var maxEllipseRadius = 0.0, maxBoxReach = 0.0
        for (y, span) in s.rows {
            for x in [Double(span.0), Double(span.1)] {
                let dx = x - cx, dy = Double(y) - cy
                let u = dx * cosA + dy * sinA, v = -dx * sinA + dy * cosA
                maxEllipseRadius = max(maxEllipseRadius, (u * u) / (a * a) + (v * v) / (b * b))
                maxBoxReach = max(maxBoxReach, max(abs(u) / (length / 2), abs(v) / (width / 2)))
            }
        }

        let ellipseOK = ellipseError < 0.05 && maxEllipseRadius < 1.18
        let rectOK = rectError < 0.05 && maxBoxReach < 1.08 && maxEllipseRadius > 1.2
        if ellipseOK && (!rectOK || ellipseError < rectError) {
            if a / b < 1.06 {
                let d = (a + b) + inflate
                return DiagramShape(kind: .circle, center: center, length: d, width: d, rotationDegrees: 0)
            }
            return DiagramShape(kind: .ellipse, center: center, length: 2 * a + inflate, width: 2 * b + inflate,
                                rotationDegrees: normalizedAngle(angle * 180 / .pi))
        }
        if rectOK {
            return DiagramShape(kind: .rectangle, center: center, length: length + inflate, width: width + inflate,
                                rotationDegrees: length / width < 1.04 ? 0 : normalizedAngle(angle * 180 / .pi))
        }
        return nil
    }

    static func normalizedAngle(_ deg: Double) -> Double {
        var a = deg.truncatingRemainder(dividingBy: 180)
        if a < 0 { a += 180 }
        if a > 179.5 { a = 0 }
        return a
    }

    /// All table-like shapes: insides of outlines, and solid filled shapes, with edges refined
    /// to a fraction of a pixel. When tables set the scale, a one-pixel bias on a 70-pixel table
    /// is over a foot of error across a ballroom.
    public static func shapes(in image: CGImage) -> [DiagramShape] {
        guard let g = Gray(image) else { return [] }
        let w = g.width, h = g.height
        let ink = inkMask(g)
        let minPixels = max(60, w * h / 40000)
        let maxPixels = w * h / 6
        // Rough sizes first: an inside region stops short of its line's middle by the grown
        // pixels plus half a line; a solid region grew by the same pixels all round.
        let insides = regions(of: ink, target: false, width: w, height: h, minPixels: minPixels, maxPixels: maxPixels)
            .compactMap { shape(of: $0, inflate: Double(2 * growPixels + 2)) }
            .compactMap { refine($0, gray: g, edge: .line) }
        let solids = regions(of: ink, target: true, width: w, height: h, minPixels: minPixels, maxPixels: maxPixels)
            .compactMap { shape(of: $0, inflate: -Double(2 * growPixels)) }
            .compactMap { refine($0, gray: g, edge: .step) }
        // Pixel indices have their centers at whole numbers; image coordinates put them half a pixel in.
        return (insides + solids).map { s in
            var s = s
            s.center = s.center + PlanPoint(x: 0.5, y: 0.5)
            return s
        }
    }

    enum Edge { case line, step }

    /// Gray value between pixel centers, so edges can be placed between pixels.
    static func sample(_ g: Gray, _ x: Double, _ y: Double) -> Double? {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        guard x0 >= 0, y0 >= 0, x0 + 1 < g.width, y0 + 1 < g.height else { return nil }
        let fx = x - Double(x0), fy = y - Double(y0)
        let w = g.width
        let a = Double(g.pixels[y0 * w + x0]), b = Double(g.pixels[y0 * w + x0 + 1])
        let c = Double(g.pixels[(y0 + 1) * w + x0]), d = Double(g.pixels[(y0 + 1) * w + x0 + 1])
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Where along a ray the edge is, in pixels from `origin`, searching `from`...`to`.
    /// A line edge is the darkness-weighted middle of the line's upper half; a step edge is
    /// where brightness crosses halfway between the fill and what's outside.
    static func edgeDistance(_ g: Gray, origin: PlanPoint, direction d: PlanPoint, from: Double, to: Double, expected: Double, edge: Edge) -> Double? {
        edgeMeasure(g, origin: origin, direction: d, from: from, to: to, expected: expected, edge: edge)?.distance
    }

    /// Every edge along a ray, not just the one nearest where it was expected: each dark line's
    /// middle, or each crossing between light and dark.
    static func edgeCandidates(_ g: Gray, origin: PlanPoint, direction d: PlanPoint, from: Double, to: Double, edge: Edge) -> [Double] {
        let step = 0.25
        var ts: [Double] = [], vs: [Double] = []
        var t = from
        while t <= to {
            guard let v = sample(g, origin.x + d.x * t, origin.y + d.y * t) else { break }
            ts.append(t); vs.append(v)
            t += step
        }
        guard vs.count > 8 else { return [] }
        switch edge {
        case .line:
            let base = vs.sorted()[vs.count * 9 / 10]
            let dark = vs.map { max(0, base - $0) }
            // A tinted floor is a little darker than the page; a line is much darker.
            let cut = max(12, (dark.max() ?? 0) * 0.35)
            var out: [Double] = []
            var i = 0
            while i < dark.count {
                guard dark[i] > cut else { i += 1; continue }
                var j = i
                while j + 1 < dark.count, dark[j + 1] > cut { j += 1 }
                // A band running to the window's end is a dark area, not a line.
                if i > 0, j < dark.count - 1 {
                    let peak = dark[i...j].max()!, half = peak * 0.5
                    var sum = 0.0, moment = 0.0
                    for k in i...j where dark[k] > half { sum += dark[k] - half; moment += (dark[k] - half) * ts[k] }
                    if sum > 0 { out.append(moment / sum) }
                }
                i = j + 1
            }
            return out
        case .step:
            let sorted = vs.sorted()
            let lo = sorted[vs.count / 10], hi = sorted[vs.count * 9 / 10]
            guard hi - lo > 30 else { return [] }
            let mid = (lo + hi) / 2
            var out: [Double] = []
            for k in 1..<vs.count where (vs[k - 1] - mid) * (vs[k] - mid) < 0 {
                out.append(ts[k - 1] + (mid - vs[k - 1]) / (vs[k] - vs[k - 1]) * step)
            }
            return out
        }
    }

    /// Edge distance plus how wide the dark band was. A ray that crosses a chair touching the
    /// table sees a wider band, and its middle sits too far out.
    static func edgeMeasure(_ g: Gray, origin: PlanPoint, direction d: PlanPoint, from: Double, to: Double, expected: Double, edge: Edge) -> (distance: Double, width: Double)? {
        let step = 0.25
        var ts: [Double] = [], vs: [Double] = []
        var t = from
        while t <= to {
            guard let v = sample(g, origin.x + d.x * t, origin.y + d.y * t) else { return nil }
            ts.append(t); vs.append(v)
            t += step
        }
        guard vs.count > 8 else { return nil }
        switch edge {
        case .line:
            // Baseline: the brighter of the two ends, so a tinted floor on one side doesn't count as line.
            let base = max(vs.prefix(4).reduce(0, +) / 4, vs.suffix(4).reduce(0, +) / 4)
            let dark = vs.map { max(0, base - $0) }
            // Dark bands above half their own peak; take the one nearest the expected edge.
            var bands: [(lo: Int, hi: Int, peak: Double)] = []
            var i = 0
            let floorLevel = (dark.max() ?? 0) * 0.3
            while i < dark.count {
                guard dark[i] > max(12, floorLevel) else { i += 1; continue }
                var j = i
                while j + 1 < dark.count, dark[j + 1] > max(12, floorLevel) { j += 1 }
                bands.append((i, j, dark[i...j].max()!))
                i = j + 1
            }
            guard let band = bands.min(by: { abs(ts[($0.lo + $0.hi) / 2] - expected) < abs(ts[($1.lo + $1.hi) / 2] - expected) }) else { return nil }
            let half = band.peak * 0.5
            var sum = 0.0, moment = 0.0, lo = Double.infinity, hi = -Double.infinity
            for k in band.lo...band.hi where dark[k] > half {
                sum += dark[k] - half
                moment += (dark[k] - half) * ts[k]
                lo = min(lo, ts[k]); hi = max(hi, ts[k])
            }
            return sum > 0 ? (moment / sum, hi - lo) : nil
        case .step:
            let inside = vs.prefix(4).reduce(0, +) / 4, outside = vs.suffix(4).reduce(0, +) / 4
            guard abs(outside - inside) > 20 else { return nil }
            let mid = (inside + outside) / 2
            // Crossing nearest the expected edge.
            var best: Double?
            for k in 1..<vs.count where (vs[k - 1] - mid) * (vs[k] - mid) <= 0 && vs[k - 1] != vs[k] {
                let f = (mid - vs[k - 1]) / (vs[k] - vs[k - 1])
                let tc = ts[k - 1] + f * step
                if best == nil || abs(tc - expected) < abs(best! - expected) { best = tc }
            }
            return best.map { ($0, 0) }
        }
    }

    static func trimmedMean(_ v: [Double]) -> Double? {
        guard v.count >= 4 else { return nil }
        let s = v.sorted()
        let q = s.count / 4
        let mid = s[q..<(s.count - q)]
        return mid.reduce(0, +) / Double(mid.count)
    }

    /// Re-measures a roughly fitted shape from its edges.
    static func refine(_ shape: DiagramShape, gray g: Gray, edge: Edge) -> DiagramShape? {
        let c = shape.center
        switch shape.kind {
        case .circle, .ellipse:
            let a = shape.length / 2, b = shape.width / 2
            let rot = shape.rotationDegrees * .pi / 180
            var points: [(angle: Double, p: PlanPoint)] = []
            var widths: [Double] = []
            let n = 72
            for k in 0..<n {
                let th = Double(k) / Double(n) * 2 * .pi
                let d = PlanPoint(x: cos(th), y: sin(th))
                // Expected radius of the rough ellipse in this direction.
                let u = d.x * cos(rot) + d.y * sin(rot), v = -d.x * sin(rot) + d.y * cos(rot)
                let r0 = 1 / ((u * u) / (a * a) + (v * v) / (b * b)).squareRoot()
                guard let m = edgeMeasure(g, origin: c, direction: d, from: r0 * 0.75, to: r0 * 1.25 + 4, expected: r0, edge: edge) else { continue }
                points.append((th, c + d * m.distance))
                widths.append(m.width)
            }
            guard points.count >= n / 3 else { return shape }
            // Center from every ray: chairs sit evenly around a table, so their pull cancels.
            var center = PlanPoint(x: points.map(\.p.x).reduce(0, +) / Double(points.count),
                                   y: points.map(\.p.y).reduce(0, +) / Double(points.count))
            guard let rMean = trimmedMean(points.map { $0.p.distance(to: center) }) else { return shape }
            var keptIdx = points.indices.filter { abs(points[$0].p.distance(to: center) - rMean) < max(1.5, rMean * 0.04) }
            if keptIdx.count >= 8 {
                center = PlanPoint(x: keptIdx.map { points[$0].p.x }.reduce(0, +) / Double(keptIdx.count),
                                   y: keptIdx.map { points[$0].p.y }.reduce(0, +) / Double(keptIdx.count))
            } else {
                keptIdx = Array(points.indices)
            }
            // Size from rays that saw only the table's own line. Where chairs touch, those rays
            // see a wider dark band and land too far out. Only filter when that clearly happened.
            var sizingIdx = keptIdx
            if edge == .line, keptIdx.count >= 8 {
                let sortedWidths = keptIdx.map { widths[$0] }.sorted()
                let low = sortedWidths[sortedWidths.count / 10], mid = sortedWidths[sortedWidths.count / 2]
                if mid - low > 1.0 {
                    let limit = low + (mid - low) / 2
                    let clean = keptIdx.filter { widths[$0] <= limit }
                    // Clean rays must still come from all round the table.
                    let quadrants = Set(clean.map { Int((points[$0].angle / (.pi / 2)).rounded(.down)) % 4 })
                    if clean.count >= 8, quadrants.count == 4 { sizingIdx = clean }
                }
            }
            let sizing = sizingIdx.map { points[$0] }
            // Extents across and down, for how oval it is; diameter from all directions.
            func extent(_ around: Double) -> Double? {
                let r = sizing.filter { abs(remainder($0.angle - around, 2 * .pi)) < 0.35 }.map { $0.p.distance(to: center) }
                return r.isEmpty ? nil : r.reduce(0, +) / Double(r.count)
            }
            guard let r = trimmedMean(sizing.map { $0.p.distance(to: center) }) ?? sizing.first.map({ $0.p.distance(to: center) }) else { return shape }
            if shape.kind == .circle {
                // A round that's a fraction of a percent wider than tall means the straightened
                // photo's proportions are off. Keep that, so the page can be corrected.
                if let hx = extent(0).flatMap({ x in extent(.pi).map { (x + $0) / 2 } }),
                   let vy = extent(.pi / 2).flatMap({ y in extent(3 * .pi / 2).map { (y + $0) / 2 } }),
                   abs(hx / vy - 1) > 0.003 {
                    let wide = hx > vy
                    return DiagramShape(kind: .ellipse, center: center, length: 2 * max(hx, vy), width: 2 * min(hx, vy),
                                        rotationDegrees: wide ? 0 : 90)
                }
                return DiagramShape(kind: .circle, center: center, length: 2 * r, width: 2 * r, rotationDegrees: 0)
            }
            // Ellipse: keep its turn, rescale its axes to the measured extents.
            if let hx = extent(0).flatMap({ x in extent(.pi).map { (x + $0) / 2 } }),
               let vy = extent(.pi / 2).flatMap({ y in extent(3 * .pi / 2).map { (y + $0) / 2 } }) {
                let ca = cos(rot), sa = sin(rot)
                // Solve for semi-axes from horizontal and vertical extents.
                let det = ca * ca * ca * ca - sa * sa * sa * sa
                if abs(det) > 0.2 {
                    let A2 = (hx * hx * ca * ca - vy * vy * sa * sa) / det
                    let B2 = (vy * vy * ca * ca - hx * hx * sa * sa) / det
                    if A2 > 0, B2 > 0 {
                        return DiagramShape(kind: .ellipse, center: center, length: 2 * A2.squareRoot(), width: 2 * B2.squareRoot(),
                                            rotationDegrees: shape.rotationDegrees)
                    }
                }
            }
            return DiagramShape(kind: .ellipse, center: center, length: shape.length, width: shape.width, rotationDegrees: shape.rotationDegrees)
        case .rectangle:
            let rot = shape.rotationDegrees * .pi / 180
            let ax = PlanPoint(x: cos(rot), y: sin(rot)), ay = PlanPoint(x: -sin(rot), y: cos(rot))
            let hl = shape.length / 2, hw = shape.width / 2
            func side(_ normal: PlanPoint, along: PlanPoint, half: Double, span: Double) -> Double? {
                var ds: [Double] = []
                for f in stride(from: -0.35, through: 0.35, by: 0.1) {
                    let o = c + along * (f * span * 2)
                    if let d = edgeDistance(g, origin: o, direction: normal, from: half * 0.6, to: half + 5, expected: half, edge: edge) {
                        ds.append(d)
                    }
                }
                return ds.count >= 3 ? ds.sorted()[ds.count / 2] : nil
            }
            guard let right = side(ax, along: ay, half: hl, span: hw), let left = side(ax * -1, along: ay, half: hl, span: hw),
                  let down = side(ay, along: ax, half: hw, span: hl), let up = side(ay * -1, along: ax, half: hw, span: hl) else { return shape }
            let center = c + ax * ((right - left) / 2) + ay * ((down - up) / 2)
            return DiagramShape(kind: .rectangle, center: center, length: right + left, width: down + up,
                                rotationDegrees: shape.rotationDegrees)
        }
    }
}
