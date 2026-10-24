import Foundation

/// An oriented rectangle on the plan, in feet. `length` runs along the item's own x axis
/// before rotation, `width` along its own y axis.
public struct Footprint: Codable, Hashable, Sendable {
    public var center: PlanPoint
    public var length: Double
    public var width: Double
    public var rotationDegrees: Double

    public init(center: PlanPoint, length: Double, width: Double, rotationDegrees: Double) {
        self.center = center
        self.length = length
        self.width = width
        self.rotationDegrees = rotationDegrees
    }

    public func inflated(by d: Double) -> Footprint {
        Footprint(center: center, length: length + 2 * d, width: width + 2 * d, rotationDegrees: rotationDegrees)
    }

    private func toLocal(_ p: PlanPoint) -> PlanPoint {
        (p - center).rotated(degrees: -rotationDegrees)
    }

    public func contains(_ p: PlanPoint) -> Bool {
        let l = toLocal(p)
        return abs(l.x) <= length / 2 && abs(l.y) <= width / 2
    }

    public var corners: [PlanPoint] {
        let hl = length / 2, hw = width / 2
        return [PlanPoint(x: -hl, y: -hw), PlanPoint(x: hl, y: -hw), PlanPoint(x: hl, y: hw), PlanPoint(x: -hl, y: hw)]
            .map { center + $0.rotated(degrees: rotationDegrees) }
    }

    /// Distance along the ray from `origin` in unit direction `dir` to where it first enters
    /// this rectangle, or nil if it never does. Returns 0 when the origin is inside.
    public func rayEntry(from origin: PlanPoint, direction dir: PlanPoint) -> Double? {
        let o = toLocal(origin)
        let d = dir.rotated(degrees: -rotationDegrees)
        guard let (tMin, tMax) = Footprint.slab(origin: o, dir: d,
                                                min: PlanPoint(x: -length / 2, y: -width / 2),
                                                max: PlanPoint(x: length / 2, y: width / 2)) else { return nil }
        if tMax < 0 { return nil }
        return Swift.max(0, tMin)
    }

    /// Slab test against an axis-aligned box. Returns the entry and exit distances.
    static func slab(origin o: PlanPoint, dir d: PlanPoint, min lo: PlanPoint, max hi: PlanPoint) -> (Double, Double)? {
        var tMin = -Double.infinity, tMax = Double.infinity
        for (oc, dc, l, h) in [(o.x, d.x, lo.x, hi.x), (o.y, d.y, lo.y, hi.y)] {
            if abs(dc) < 1e-12 {
                if oc < l || oc > h { return nil }
            } else {
                var t1 = (l - oc) / dc, t2 = (h - oc) / dc
                if t1 > t2 { swap(&t1, &t2) }
                tMin = Swift.max(tMin, t1)
                tMax = Swift.min(tMax, t2)
                if tMin > tMax { return nil }
            }
        }
        return (tMin, tMax)
    }
}

extension RoomSize {
    /// Distance from a point inside the room to the wall along a unit direction.
    public func distanceToWall(from p: PlanPoint, direction d: PlanPoint) -> Double {
        guard let (_, tMax) = Footprint.slab(origin: p, dir: d,
                                             min: PlanPoint(x: 0, y: 0),
                                             max: PlanPoint(x: widthFt, y: depthFt)) else { return 0 }
        return Swift.max(0, tMax)
    }
}
