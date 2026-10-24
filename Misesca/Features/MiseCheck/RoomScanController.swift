import ARKit
import RoomPlan
import MisescaKit

/// Runs a RoomPlan capture on Set Mode's own ARSession, so scanned objects come back
/// in the same world coordinates as the alignment.
@MainActor
final class RoomScanController: NSObject, RoomCaptureSessionDelegate {
    static var isSupported: Bool { RoomCaptureSession.isSupported }

    var onTablesSeen: ((Int) -> Void)?
    var onInstruction: ((String?) -> Void)?
    var onFinished: ((Result<[CapturedRoom.Object], Error>) -> Void)?

    private var session: RoomCaptureSession?
    private var lastRoom: CapturedRoom?

    func start(on arSession: ARSession) {
        let s = RoomCaptureSession(arSession: arSession)
        s.delegate = self
        session = s
        lastRoom = nil
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = false
        s.run(configuration: config)
    }

    /// Stops scanning but keeps the AR session running so the ghosts stay put.
    func finish() {
        session?.stop(pauseARSession: false)
    }

    func cancel() {
        onFinished = nil
        session?.stop(pauseARSession: false)
        session = nil
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let count = room.objects.filter { $0.category == .table }.count
        Task { @MainActor in
            self.lastRoom = room
            self.onTablesSeen?(count)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String?
        switch instruction {
        case .moveCloseToWall: text = "Move a little closer."
        case .moveAwayFromWall: text = "Step back a little."
        case .slowDown: text = "Slow down."
        case .turnOnLight: text = "It's too dark to scan. Turn up the lights."
        case .lowTexture: text = "Point at the tables, not the bare floor."
        case .normal: text = nil
        @unknown default: text = nil
        }
        Task { @MainActor in self.onInstruction?(text) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            defer { self.session = nil }
            guard let finished = self.onFinished else { return }
            if let error {
                // A partial room is still useful if RoomPlan had produced one.
                if let room = self.lastRoom { finished(.success(room.objects)) } else { finished(.failure(error)) }
                return
            }
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                finished(.success(room.objects))
            } catch {
                if let room = self.lastRoom { finished(.success(room.objects)) } else { finished(.failure(error)) }
            }
        }
    }

    /// Converts scanned objects into plan coordinates using the current alignment.
    static func detectedObjects(_ objects: [CapturedRoom.Object], alignment: PlanAlignment) -> [DetectedObject] {
        objects.map { obj in
            let t = obj.transform
            let center = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
            let heading = atan2(Double(t.columns.0.z), Double(t.columns.0.x))
            let footprint = Footprint(
                center: alignment.plan(center),
                length: Units.feet(Double(obj.dimensions.x)),
                width: Units.feet(Double(obj.dimensions.z)),
                rotationDegrees: alignment.planRotationDegrees(worldHeading: heading)
            )
            return DetectedObject(footprint: footprint, isTable: obj.category == .table)
        }
    }
}
