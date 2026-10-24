import Foundation
import simd

public enum Units {
    public static let metersPerFoot = 0.3048
    public static func meters(_ feet: Double) -> Double { feet * metersPerFoot }
    public static func feet(_ meters: Double) -> Double { meters / metersPerFoot }

    /// "8 in", "19 in", "3 ft", "3.5 ft". Short distances read better in inches.
    public static func describe(feet: Double) -> String {
        let f = abs(feet)
        if f < 2 {
            return "\(Int((f * 12).rounded())) in"
        }
        let half = (f * 2).rounded() / 2
        return half == half.rounded() ? "\(Int(half)) ft" : String(format: "%.1f ft", half)
    }
}

/// Maps plan coordinates (feet, y down the page) onto the AR world floor (meters, y up)
/// using two reference points. Translation plus rotation about the vertical axis; scale is fixed at 1:1.
///
/// Plan x maps to world x and plan y maps to world z, which keeps handedness: seen from
/// above with world x to the right, world z points down the page just like plan y.
public struct PlanAlignment: Codable, Equatable, Sendable {
    public var planA: PlanPoint
    public var planB: PlanPoint
    public var worldA: SIMD3<Double>
    public var worldB: SIMD3<Double>
    /// Rotation from plan axes to world x/z axes, in radians.
    public var yaw: Double
    public var floorY: Double

    public init(planA: PlanPoint, planB: PlanPoint, worldA: SIMD3<Double>, worldB: SIMD3<Double>) {
        self.planA = planA
        self.planB = planB
        self.worldA = worldA
        self.worldB = worldB
        let dp = planB - planA
        let dw = worldB - worldA
        yaw = atan2(dw.z, dw.x) - atan2(dp.y, dp.x)
        floorY = (worldA.y + worldB.y) / 2
    }

    public func world(_ p: PlanPoint) -> SIMD3<Double> {
        let v = (p - planA) * Units.metersPerFoot
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(worldA.x + c * v.x - s * v.y, floorY, worldA.z + s * v.x + c * v.y)
    }

    public func plan(_ w: SIMD3<Double>) -> PlanPoint {
        let vx = w.x - worldA.x, vz = w.z - worldA.z
        let c = cos(-yaw), s = sin(-yaw)
        let local = PlanPoint(x: c * vx - s * vz, y: s * vx + c * vz)
        return planA + local * (1 / Units.metersPerFoot)
    }

    /// Converts a heading in the world x/z plane (radians, atan2(z, x)) into plan rotation degrees.
    public func planRotationDegrees(worldHeading: Double) -> Double {
        var deg = (worldHeading - yaw) * 180 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg
    }

    public var distanceCheck: DistanceCheck {
        let worldFt = Units.feet(simd_distance(SIMD2(worldA.x, worldA.z), SIMD2(worldB.x, worldB.z)))
        return DistanceCheck(planFt: planA.distance(to: planB), worldFt: worldFt)
    }
}

/// Compares the real distance between the two taps with the plan.
public struct DistanceCheck: Equatable, Sendable {
    public var planFt: Double
    public var worldFt: Double
    public static let allowedFraction = 0.10

    public init(planFt: Double, worldFt: Double) {
        self.planFt = planFt
        self.worldFt = worldFt
    }

    public var differenceFt: Double { worldFt - planFt }
    public var isAcceptable: Bool { abs(differenceFt) <= planFt * Self.allowedFraction }

    public var message: String? {
        guard !isAcceptable else { return nil }
        let amount = Units.describe(feet: differenceFt)
        let way = differenceFt > 0 ? "farther apart" : "closer together"
        return "Your two points are \(amount) \(way) than the plan says. Check them and try again."
    }
}
