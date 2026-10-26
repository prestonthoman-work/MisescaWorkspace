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

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// The same image at another scale: box-averaged when shrinking, bilinear when enlarging.
        func resized(by f: Double) -> Gray? {
            let nw = Int(Double(width) * f), nh = Int(Double(height) * f)
            guard nw >= 16, nh >= 16 else { return nil }
            var out = [UInt8](repeating: 255, count: nw * nh)
            if f < 1 {
                let k = Int((1 / f).rounded())
                for y in 0..<nh {
                    for x in 0..<nw {
                        var sum = 0
                        for dy in 0..<k { for dx in 0..<k { sum += Int(pixels[(y * k + dy) * width + x * k + dx]) } }
                        out[y * nw + x] = UInt8(sum / (k * k))
                    }
                }
            } else {
                for y in 0..<nh {
                    let sy = min(max((Double(y) + 0.5) / f - 0.5, 0), Double(height - 1))
                    let y0 = min(Int(sy), height - 2), fy = sy - Double(y0)
                    for x in 0..<nw {
                        let sx = min(max((Double(x) + 0.5) / f - 0.5, 0), Double(width - 1))
                        let x0 = min(Int(sx), width - 2), fx = sx - Double(x0)
                        let a = Double(pixels[y0 * width + x0]), b = Double(pixels[y0 * width + x0 + 1])
                        let c = Double(pixels[(y0 + 1) * width + x0]), d = Double(pixels[(y0 + 1) * width + x0 + 1])
                        out[y * nw + x] = UInt8(((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy).rounded())
                    }
                }
            }
            return Gray(width: nw, height: nh, pixels: out)
        }
    }

    /// Ink is any pixel clearly darker than its neighborhood, so faint gray lines on a gray
    /// floor count as well as black lines on white. Thin gaps are closed by growing ink one pixel.
    static let growPixels = 2

    /// `findLines` also finds faint lines in a grainy photo by their shape. It's for table
    /// outlines; walls are found from ink alone, which the extra lines would confuse.
    static func inkMask(_ g: Gray, findLines: Bool = false) -> [Bool] {
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
        // In a noisy photo a faint line can be barely darker than the floor's grain, so darkness
        // alone leaves gaps in it and speckles the floor. Its shape gives it away: across a line,
        // brightness dips sharply in one direction only, where grain dips in round specks.
        if findLines && sigma >= ridgeNoise {
            for i in ridgePixels(g) where !ink[i] {
                ink[i] = true
                stack.append(i)
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

    /// Noise level, in gray steps between neighbors, above which an image is treated as a photo
    /// and lines are also found by their shape. Clean exports measure close to zero.
    static let ridgeNoise = 1.5
    /// Smoothing for finding lines by shape, in pixels: about half a photographed line's width.
    static let ridgeSmoothing: Float = 2.5
    /// How far above the image's typical curvature a line must stand out.
    static let ridgeStrength: Float = 3

    /// Pixels on thin dark lines: where brightness, smoothed, curves up sharply across one
    /// direction and little along the other. Indices into the image, row by row.
    static func ridgePixels(_ g: Gray) -> [Int] {
        let w = g.width, h = g.height
        guard w > 8, h > 8 else { return [] }
        let smooth = gaussian(g, sd: ridgeSmoothing)
        // Curvature: the larger eigenvalue of the second derivatives is the dip across a line.
        var strongest = [Float](repeating: 0, count: w * h)
        var lineLike = [Bool](repeating: false, count: w * h)
        var sample: [Float] = []
        sample.reserveCapacity(w * h / 16)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let dxx = smooth[i + 1] + smooth[i - 1] - 2 * smooth[i]
                let dyy = smooth[i + w] + smooth[i - w] - 2 * smooth[i]
                let dxy = (smooth[i + w + 1] - smooth[i + w - 1] - smooth[i - w + 1] + smooth[i - w - 1]) / 4
                let half = (dxx - dyy) / 2
                let root = (half * half + dxy * dxy).squareRoot()
                let big = (dxx + dyy) / 2 + root, small = (dxx + dyy) / 2 - root
                strongest[i] = big
                // A round speck curves the same both ways; a line hardly at all along itself.
                lineLike[i] = big > 0 && small < big * 0.4
                if x % 4 == 0 && y % 4 == 0 { sample.append(abs(big)) }
            }
        }
        sample.sort()
        guard let typical = sample.isEmpty ? nil : sample[sample.count / 2], typical > 0 else { return [] }
        let bar = typical * ridgeStrength
        var out: [Int] = []
        for i in 0..<(w * h) where lineLike[i] && strongest[i] > bar { out.append(i) }
        return out
    }

    /// The image blurred by a Gaussian of `sd` pixels, separably.
    static func gaussian(_ g: Gray, sd: Float) -> [Float] {
        let w = g.width, h = g.height
        let radius = Int((sd * 3).rounded(.up))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sd * sd)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var across = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v: Float = 0
                for k in -radius...radius {
                    let xx = min(max(x + k, 0), w - 1)
                    v += kernel[k + radius] * Float(g.pixels[y * w + xx])
                }
                across[y * w + x] = v
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v: Float = 0
                for k in -radius...radius {
                    let yy = min(max(y + k, 0), h - 1)
                    v += kernel[k + radius] * across[yy * w + x]
                }
                out[y * w + x] = v
            }
        }
        return out
    }

    /// Typical difference between neighboring pixels: about zero for a clean export, several
    /// gray steps for a phone photo.
    static func grain(_ g: Gray) -> Int {
        var diffs: [Int] = []
        for y in stride(from: 1, to: g.height, by: 4) {
            for x in stride(from: 1, to: g.width, by: 4) { diffs.append(abs(Int(g.pixels[y * g.width + x]) - Int(g.pixels[y * g.width + x - 1]))) }
        }
        diffs.sort()
        return diffs.isEmpty ? 0 : diffs[diffs.count / 2]
    }

    /// Per-region running totals, collected from horizontal runs of pixels.
    struct RegionStats {
        var pixels = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var touchesEdge = false
        /// Leftmost and rightmost pixel of each row, for the filled (hole-free) shape.
        var rows: [Int: (Int, Int)] = [:]
        /// Widest hole crossed by any row. Letters written on a table leave narrow holes;
        /// the middle of a ring or frame leaves one wide one.
        var widestGap = 0
    }

    /// Connected regions of `target` pixels (4-connected), labelled with union-find over runs.
    static func regions(of mask: [Bool], target: Bool, width w: Int, height h: Int, minPixels: Int, maxPixels: Int,
                        keepEdge: Bool = false) -> [RegionStats] {
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
                // Runs arrive left to right, so the gap is from the row's right end so far.
                s.widestGap = max(s.widestGap, r.x0 - existing.1 - 1)
                s.rows[r.y] = (min(existing.0, r.x0), max(existing.1, r.x1))
            } else {
                s.rows[r.y] = (r.x0, r.x1)
            }
            stats[root] = s
        }
        return stats.values.filter { (keepEdge || !$0.touchesEdge) && $0.pixels >= minPixels && $0.pixels <= maxPixels }
    }

    /// Shape of a region from its filled row spans: centroid, principal axes, and fit tests.
    static func shape(of s: RegionStats, inflate: Double, ink: Bool = false) -> DiagramShape? {
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
        // mostly holes is a ring or a frame, not a table. "Table 12" written across a small
        // table can hide nearly half of it, so many narrow holes are still a table.
        let solidity = Double(s.pixels) / area
        let narrowHoles = Double(s.widestGap) < Double(s.maxX - s.minX + 1) * 0.35
        guard solidity > 0.55 || (solidity > 0.3 && narrowHoles) else { return nil }
        // Solid ink with a wide hole is a ring, such as a table and its chairs run together.
        if ink && !narrowHoles && solidity < 0.8 { return nil }

        let cx = sx / area, cy = sy / area
        let vxx = sxx / area - cx * cx, vyy = syy / area - cy * cy, vxy = sxy / area - cx * cy
        let tr = vxx + vyy, det = vxx * vyy - vxy * vxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-9)
        let center = PlanPoint(x: cx, y: cy)

        var angle = 0.5 * atan2(2 * vxy, vxx - vyy)
        // A square spreads the same way in every direction, so its moments say nothing about
        // its turn. Take the turn of the smallest box around its outline instead.
        if l1 / l2 < 1.15 {
            let outline = s.rows.flatMap { y, span in [PlanPoint(x: Double(span.0), y: Double(y)), PlanPoint(x: Double(span.1), y: Double(y))] }
            if let box = ShapeClassifier.minimumAreaRectangle(ShapeClassifier.convexHull(outline)) {
                angle = box.rotationDegrees * .pi / 180
            }
        }
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
        var u0 = Double.infinity, u1 = -Double.infinity, v0 = Double.infinity, v1 = -Double.infinity
        for (y, span) in s.rows {
            for x in [Double(span.0), Double(span.1)] {
                let dx = x - cx, dy = Double(y) - cy
                let u = dx * cosA + dy * sinA, v = -dx * sinA + dy * cosA
                maxEllipseRadius = max(maxEllipseRadius, (u * u) / (a * a) + (v * v) / (b * b))
                maxBoxReach = max(maxBoxReach, max(abs(u) / (length / 2), abs(v) / (width / 2)))
                u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
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
            // A square looks the same a quarter turn round, so only its turn within 90 degrees counts.
            var turn = normalizedAngle(angle * 180 / .pi)
            if length / width < 1.04 {
                turn = turn.truncatingRemainder(dividingBy: 90)
                if turn > 89.5 || turn < 0.5 { turn = 0 }
            }
            return DiagramShape(kind: .rectangle, center: center, length: length + inflate, width: width + inflate,
                                rotationDegrees: turn)
        }
        // Neither: keep its turned bounding box, for a named bar or table of an unusual shape.
        // Mostly-hollow regions are line work, not objects.
        guard solidity > 0.55 else { return nil }
        let mid = PlanPoint(x: (u0 + u1) / 2, y: (v0 + v1) / 2)
        let boxCenter = center + PlanPoint(x: mid.x * cosA - mid.y * sinA, y: mid.x * sinA + mid.y * cosA)
        // Row ends are pixel centers; the region reaches half a pixel further.
        var l = u1 - u0 + 1 + inflate, wd = v1 - v0 + 1 + inflate, turn = angle * 180 / .pi
        if wd > l { swap(&l, &wd); turn += 90 }
        guard l > 0, wd > 0 else { return nil }
        return DiagramShape(kind: .other, center: boxCenter, length: l, width: wd, rotationDegrees: normalizedAngle(turn))
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
    ///
    /// The image is searched at more than one scale. Full size finds most things. Half size
    /// joins up outlines that are broken, blurred or patterned in a photo, and big objects.
    /// A small image is also searched at double size, so a small table's inside isn't closed
    /// up by the ink growing over it. Every shape is measured on the full-size image.
    public static func shapes(in image: CGImage) -> [DiagramShape] {
        Scan(image).map { shapes(in: $0) } ?? []
    }

    /// One image made ready for finding shapes, so the work is shared between passes.
    public struct Scan {
        let gray: Gray
        /// Ink at full size, with faint lines found by their shape.
        let ink: [Bool]
        /// What edges are measured on: the image itself, or for a grainy photo a lightly smoothed
        /// copy, so grain doesn't pull edges about.
        let edges: Gray

        public init?(_ image: CGImage) {
            guard let g = Gray(image) else { return nil }
            gray = g
            ink = inkMask(g, findLines: true)
            edges = grain(g) >= 3
                ? Gray(width: g.width, height: g.height, pixels: gaussian(g, sd: 1).map { UInt8(min(255, max(0, $0.rounded()))) })
                : g
        }
    }

    static func shapes(in scan: Scan) -> [DiagramShape] {
        let g = scan.gray
        var found = roughShapes(g, ink: scan.ink)
        // Other scales only fill in places where nothing was found at full size. Coarser, a
        // table and its chairs run together into one bigger blob over the table.
        let fullSize = found.map(\.0)
        func add(_ more: [(DiagramShape, Edge)]) {
            for (s, e) in more where !fullSize.contains(where: { overlaps($0, s) })
                && !found.contains(where: { sameObject($0.0, s) }) {
                found.append((s, e))
            }
        }
        if min(g.width, g.height) >= 400, let half = g.resized(by: 0.5) {
            add(roughShapes(half).map { (scaled($0.0, by: 2), $0.1) })
        }
        if max(g.width, g.height) <= 1300, let double = g.resized(by: 2) {
            add(roughShapes(double).map { (scaled($0.0, by: 0.5), $0.1) })
        }
        return found.compactMap { refine($0.0, gray: scan.edges, edge: $0.1) }.map(toImageCoordinates)
    }

    /// A quicker look, at full size from ink alone: enough to find the round tables that set a
    /// photo's proportions while it's being straightened.
    public static func quickShapes(in image: CGImage) -> [DiagramShape] {
        guard let g = Gray(image) else { return [] }
        return roughShapes(g, ink: inkMask(g)).compactMap { refine($0.0, gray: g, edge: $0.1) }.map(toImageCoordinates)
    }

    /// Pixel indices have their centers at whole numbers; image coordinates put them half a pixel in.
    static func toImageCoordinates(_ s: DiagramShape) -> DiagramShape {
        var s = s
        s.center = s.center + PlanPoint(x: 0.5, y: 0.5)
        return s
    }

    /// Shapes hidden by their own labels. "Table 12" written across a small table cuts its
    /// inside in two; with the recognized text cleared away the whole inside shows. Each label
    /// is cleared on its own, in a window that grows until the region under it is closed, so a
    /// misread row of chairs beside a table can't open up that table's outline. Text over an
    /// outline opens it up instead, and then nothing is found there.
    public static func shapes(in image: CGImage, under texts: [DiagramText]) -> [DiagramShape] {
        Scan(image).map { shapes(in: $0, under: texts) } ?? []
    }

    static func shapes(in scan: Scan, under texts: [DiagramText]) -> [DiagramShape] {
        let boxes = texts.filter { $0.width > 0 && $0.height > 0 }
        guard !boxes.isEmpty else { return [] }
        let g = scan.gray, ink = scan.ink
        let w = g.width, h = g.height
        let minPixels = max(60, w * h / 40000), maxPixels = w * h / 6
        // Ink grew past the letters; clear that too. A table's outline running through the text
        // box stays: it crosses the box from side to side and carries on past it. Letters never
        // fill the padded box top to bottom, but grown letters do run together side to side, so a
        // line along the text must carry on well past the box to count.
        let pad = Double(growPixels + 1)
        let reach = 3 * (growPixels + 2)
        var out: [DiagramShape] = []
        for t in boxes {
            let x0 = max(reach, Int(t.center.x - t.width / 2 - pad)), x1 = min(w - 1 - reach, Int(t.center.x + t.width / 2 + pad))
            let y0 = max(1, Int(t.center.y - t.height / 2 - pad)), y1 = min(h - 2, Int(t.center.y + t.height / 2 + pad))
            guard x0 < x1, y0 < y1 else { continue }
            let lineColumns = Set((x0...x1).filter { x in (y0 - 1...y1 + 1).allSatisfy { ink[$0 * w + x] } })
            let lineRows = Set((y0...y1).filter { y in (x0 - reach...x1 + reach).allSatisfy { ink[y * w + $0] } })
            let cx = Int(t.center.x), cy = Int(t.center.y)
            var half = Int(max(t.width, t.height))
            while true {
                let wx0 = max(0, cx - half), wx1 = min(w, cx + half), wy0 = max(0, cy - half), wy1 = min(h, cy + half)
                let ww = wx1 - wx0, wh = wy1 - wy0
                var local = [Bool](repeating: false, count: ww * wh)
                for y in 0..<wh { for x in 0..<ww { local[y * ww + x] = ink[(y + wy0) * w + x + wx0] } }
                for y in y0...y1 where !lineRows.contains(y) && y >= wy0 && y < wy1 {
                    for x in x0...x1 where !lineColumns.contains(x) && x >= wx0 && x < wx1 { local[(y - wy0) * ww + x - wx0] = false }
                }
                // A region touching the window's edge may only be cut off by it; look wider. Once
                // the window is the whole image, touching the edge means it's the open floor.
                let all = regions(of: local, target: false, width: ww, height: wh, minPixels: 0, maxPixels: .max, keepEdge: true)
                // The region under the label; the floor around a table spans the label's row too, so the smallest.
                guard let r = all.filter({ r in r.rows[cy - wy0].map { $0.0 <= cx - wx0 && $0.1 >= cx - wx0 } ?? false })
                        .min(by: { $0.pixels < $1.pixels }),
                      r.pixels <= maxPixels else { break }
                if r.touchesEdge {
                    if wx0 == 0 && wy0 == 0 && wx1 == w && wy1 == h { break }
                    half *= 2
                    continue
                }
                if r.pixels >= minPixels, var shape = shape(of: r, inflate: Double(2 * growPixels + 2)) {
                    shape.center = shape.center + PlanPoint(x: Double(wx0), y: Double(wy0))
                    let box = Footprint(center: shape.center, length: shape.length, width: shape.width, rotationDegrees: shape.rotationDegrees)
                    if box.contains(t.center), let refined = refine(shape, gray: scan.edges, edge: .line) {
                        out.append(toImageCoordinates(refined))
                    }
                }
                break
            }
        }
        return out
    }

    /// Shapes at one scale, before their edges are measured, in that scale's pixel indices.
    static func roughShapes(_ g: Gray, ink given: [Bool]? = nil) -> [(DiagramShape, Edge)] {
        let w = g.width, h = g.height
        let ink = given ?? inkMask(g, findLines: true)
        let minPixels = max(60, w * h / 40000)
        let maxPixels = w * h / 6
        // Rough sizes first: an inside region stops short of its line's middle by the grown
        // pixels plus half a line; a solid region grew by the same pixels all round.
        let insides = regions(of: ink, target: false, width: w, height: h, minPixels: minPixels, maxPixels: maxPixels)
            .compactMap { shape(of: $0, inflate: Double(2 * growPixels + 2)) }
            .map { ($0, Edge.line) }
        let solids = regions(of: ink, target: true, width: w, height: h, minPixels: minPixels, maxPixels: maxPixels)
            .compactMap { shape(of: $0, inflate: -Double(2 * growPixels), ink: true) }
            .map { ($0, Edge.step) }
        return insides + solids
    }

    /// From another scale's pixel indices into full-size ones. Pixel i at scale k covers
    /// full-size pixels from i/k to (i+1)/k, so its center is at (i + 0.5)/k - 0.5.
    static func scaled(_ s: DiagramShape, by f: Double) -> DiagramShape {
        var s = s
        s.center = PlanPoint(x: (s.center.x + 0.5) * f - 0.5, y: (s.center.y + 0.5) * f - 0.5)
        s.length *= f
        s.width *= f
        return s
    }

    /// Either shape's center lies inside the other.
    static func overlaps(_ a: DiagramShape, _ b: DiagramShape) -> Bool {
        func box(_ s: DiagramShape) -> Footprint {
            Footprint(center: s.center, length: s.length, width: s.width, rotationDegrees: s.rotationDegrees)
        }
        return box(a).contains(b.center) || box(b).contains(a.center)
    }

    /// The same object seen twice: centers close together and sizes alike.
    static func sameObject(_ a: DiagramShape, _ b: DiagramShape) -> Bool {
        let size = min(a.width, b.width)
        let ratio = (a.length * a.width) / max(b.length * b.width, 1e-9)
        return a.center.distance(to: b.center) < max(2, size * 0.3) && ratio > 0.6 && ratio < 1 / 0.6
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
        case .other:
            // No single edge to follow; the region's box is as close as it gets.
            return shape
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
