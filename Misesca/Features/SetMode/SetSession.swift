import ARKit
import AVFoundation
import Combine
import Observation
import RealityKit
import RoomPlan
import UIKit
import MisescaKit

enum SetPhase: Equatable {
    case unsupported
    case cameraDenied
    case findingFloor
    case tapA
    case tapB
    case mismatch(DistanceCheck)
    case placing
    case scanReady
    case scanning
    case processing
    case pointCheck
}

/// Everything that happens on the AR screen: alignment, ghosts, marking, and Mise Check.
@MainActor
@Observable
final class SetSession: NSObject, ARSessionDelegate {
    let layout: EventLayout
    let arView: ARView
    private(set) var phase: SetPhase = .findingFloor
    private(set) var placed: [String]
    /// Short guidance from tracking or the last action. Nil when there's nothing to say.
    private(set) var hint: String?
    /// Stays up until alignment succeeds, unlike `hint`, which tracking updates replace.
    private(set) var notice: String?
    private(set) var tablesSeen = 0
    private(set) var pointChecks: [PlanPoint] = []
    private(set) var lastPointResult: String?
    private(set) var report: CheckReport?
    private(set) var focus: IssueRef?
    var presentingReport = false

    var onPlacedChanged: (([String]) -> Void)?
    var onReport: ((CheckReport) -> Void)?

    @ObservationIgnored private let toleranceInches: Double
    @ObservationIgnored private var alignment: PlanAlignment?
    @ObservationIgnored private var pointA: SIMD3<Float>?
    @ObservationIgnored private var markerAnchors: [AnchorEntity] = []
    @ObservationIgnored private var layoutAnchor: AnchorEntity?
    @ObservationIgnored private var ghosts: [String: ModelEntity] = [:]
    @ObservationIgnored private var labels: [Entity] = []
    @ObservationIgnored private var focusEntity: Entity?
    @ObservationIgnored private var fixedSinceReport: Set<String> = []
    @ObservationIgnored private var fadeProgress: Float = 1
    @ObservationIgnored private var updateSubscription: Cancellable?
    @ObservationIgnored private let scanner = RoomScanController()
    @ObservationIgnored private var started = false

    init(layout: EventLayout, placed: [String], toleranceInches: Double) {
        self.layout = layout
        self.placed = placed
        self.toleranceInches = toleranceInches
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)
        arView.session.delegate = self
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(Float(event.deltaTime))
        }
    }

    var settings: CheckSettings { CheckSettings(toleranceInches: toleranceInches) }
    var placedCount: Int { Set(placed).count }
    var isAligned: Bool { alignment != nil }

    // MARK: Session

    func start() {
        guard !started else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .unsupported
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied
            || AVCaptureDevice.authorizationStatus(for: .video) == .restricted {
            phase = .cameraDenied
            return
        }
        started = true
        runTracking(reset: true)
        phase = .findingFloor
        hint = "Point at the floor and move slowly."
    }

    func stop() {
        scanner.cancel()
        arView.session.pause()
        started = false
    }

    private func runTracking(reset: Bool) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        // RoomPlan can take over the session's delegate while scanning; take it back.
        arView.session.delegate = self
        arView.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let foundFloor = anchors.contains { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }
        guard foundFloor else { return }
        MainActor.assumeIsolated {
            if phase == .findingFloor {
                phase = .tapA
                hint = nil
            }
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        MainActor.assumeIsolated {
            switch state {
            case .normal:
                if phase == .findingFloor { hint = "Point at the floor and move slowly." } else { hint = nil }
            case .notAvailable:
                hint = "Tracking isn't available. Hold still for a moment."
            case .limited(let reason):
                switch reason {
                case .excessiveMotion: hint = "Slow down."
                case .insufficientFeatures: hint = "Not enough detail. Turn up the lights or point at the floor."
                case .initializing: hint = "Point at the floor and move slowly."
                case .relocalizing: hint = "Hold steady. Finding your place again."
                @unknown default: hint = nil
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let denied = (error as? ARError)?.code == .cameraUnauthorized
        MainActor.assumeIsolated {
            if denied {
                phase = .cameraDenied
            } else {
                hint = "The camera stopped. Close Set Mode and open it again."
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { hint = "Camera paused." }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            // Tracking can shift while the camera is off, so the ghosts may no longer match the floor.
            // Take them down and ask for the two points again rather than let the crew set to a moved layout.
            guard alignment != nil || pointA != nil || pendingAlignment != nil else { return }
            clearFocus()
            realign()
            notice = "The camera paused, so the layout may have moved. Tap A and B again."
        }
    }

    // MARK: Alignment

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: arView)
        switch phase {
        case .tapA, .tapB:
            tapFloor(at: point)
        case .placing:
            tapGhost(at: point)
        default:
            break
        }
    }

    private func floorHit(at point: CGPoint) -> SIMD3<Float>? {
        let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let t = hit?.worldTransform else { return nil }
        return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    private func tapFloor(at point: CGPoint) {
        guard let p = floorHit(at: point) else {
            hint = "Couldn't find the floor there. Point at the floor and tap again."
            return
        }
        hint = nil
        if phase == .tapA {
            pointA = p
            addMarker("A", at: p)
            phase = .tapB
            return
        }
        guard let a = pointA else { phase = .tapA; return }
        addMarker("B", at: p)
        let candidate = PlanAlignment(planA: layout.referencePoints.a.point, planB: layout.referencePoints.b.point,
                                      worldA: SIMD3<Double>(a), worldB: SIMD3<Double>(p))
        let check = candidate.distanceCheck
        if check.isAcceptable {
            commit(candidate)
        } else {
            alignment = nil
            pendingAlignment = candidate
            phase = .mismatch(check)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    @ObservationIgnored private var pendingAlignment: PlanAlignment?

    /// The crew checked the spots and wants to go ahead anyway.
    func acceptMismatch() {
        guard let candidate = pendingAlignment else { return }
        commit(candidate)
    }

    func redoPoints() {
        clearMarkers()
        pendingAlignment = nil
        pointA = nil
        phase = .tapA
        hint = nil
    }

    /// Start alignment over. Marks are kept; only the ghosts' position changes.
    func realign() {
        scanner.cancel()
        removeGhosts()
        alignment = nil
        redoPoints()
    }

    private func commit(_ a: PlanAlignment) {
        alignment = a
        pendingAlignment = nil
        notice = nil
        clearMarkers()
        buildGhosts(a)
        phase = .placing
        hint = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func addMarker(_ letter: String, at p: SIMD3<Float>) {
        let anchor = AnchorEntity(world: p)
        anchor.addChild(GhostFactory.makeMarker(letter: letter))
        arView.scene.addAnchor(anchor)
        markerAnchors.append(anchor)
        labels.append(contentsOf: anchor.children.compactMap { $0.findEntity(named: "label") })
    }

    private func clearMarkers() {
        for m in markerAnchors {
            labels.removeAll { $0.anchor === m }
            m.removeFromParent()
        }
        markerAnchors = []
    }

    // MARK: Ghosts

    private func buildGhosts(_ a: PlanAlignment) {
        removeGhosts()
        var transform = Transform()
        transform.translation = [Float(a.worldA.x), Float(a.floorY), Float(a.worldA.z)]
        transform.rotation = simd_quatf(angle: -Float(a.yaw), axis: [0, 1, 0])
        let anchor = AnchorEntity(world: transform.matrix)
        let origin = a.planA

        for aisle in layout.aisles {
            anchor.addChild(GhostFactory.makeAisle(aisle, origin: origin))
        }
        for item in layout.items {
            let (body, label) = GhostFactory.makeGhost(for: item, origin: origin)
            anchor.addChild(body)
            anchor.addChild(label)
            ghosts[item.id] = body
            labels.append(label)
        }
        arView.scene.addAnchor(anchor)
        layoutAnchor = anchor
        fadeProgress = 0
        refreshAllAppearances()
    }

    private func removeGhosts() {
        layoutAnchor?.removeFromParent()
        layoutAnchor = nil
        ghosts = [:]
        let markerSet = Set(markerAnchors.map(ObjectIdentifier.init))
        labels.removeAll { label in
            guard let a = label.anchor else { return true }
            return !markerSet.contains(ObjectIdentifier(a))
        }
        focusEntity = nil
    }

    private func appearance(for id: String) -> GhostAppearance {
        if focus == .table(id) { return .highlight }
        if let report, !fixedSinceReport.contains(id),
           let status = report.tables.first(where: { $0.itemID == id })?.status {
            switch status {
            case .enPlace: return .enPlace
            case .off: return .off
            case .missing: return .missing
            case .notChecked: break
            }
        }
        if placed.contains(id) { return .enPlace }
        return .ghost(opacity: GhostFactory.ghostOpacity * fadeProgress)
    }

    private func refreshAppearance(_ id: String) {
        ghosts[id]?.model?.materials = [GhostFactory.material(appearance(for: id))]
    }

    private func refreshAllAppearances() {
        for id in ghosts.keys { refreshAppearance(id) }
    }

    /// Per frame: turn labels to face the camera, and fade ghosts in after alignment.
    private func tick(_ dt: Float) {
        let cam = arView.cameraTransform.translation
        for label in labels where label.isActive {
            let p = label.position(relativeTo: nil)
            let yaw = atan2(cam.x - p.x, cam.z - p.z)
            label.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
        }
        if fadeProgress < 1, !ghosts.isEmpty {
            fadeProgress = min(1, fadeProgress + dt / 0.6)
            for (id, ghost) in ghosts where !placed.contains(id) && focus != .table(id) && report == nil {
                ghost.model?.materials = [GhostFactory.material(.ghost(opacity: GhostFactory.ghostOpacity * fadeProgress))]
            }
        }
    }

    // MARK: Placing

    private func tapGhost(at point: CGPoint) {
        guard let id = arView.entities(at: point).lazy.compactMap({ GhostFactory.itemID(from: $0.name) }).first,
              let item = layout.item(id: id) else { return }

        if !placed.contains(id) {
            placed.append(id)
            fixedSinceReport.insert(id)
            hint = nil
        } else if let status = report?.tables.first(where: { $0.itemID == id })?.status,
                  status == .off || status == .missing, !fixedSinceReport.contains(id) {
            fixedSinceReport.insert(id)
            hint = "\(item.displayName) marked en place. Run Mise Check again to confirm."
        } else {
            hint = "\(item.displayName) is already en place. Use Undo to change it."
            return
        }
        if focus == .table(id) { clearFocus() }
        refreshAppearance(id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onPlacedChanged?(placed)
    }

    func undo() {
        guard let id = placed.popLast() else { return }
        fixedSinceReport.remove(id)
        refreshAppearance(id)
        hint = nil
        onPlacedChanged?(placed)
    }

    // MARK: Mise Check

    func beginCheck() {
        clearFocus()
        if RoomScanController.isSupported {
            phase = .scanReady
        } else {
            pointChecks = []
            lastPointResult = nil
            phase = .pointCheck
        }
    }

    func cancelCheck() {
        scanner.cancel()
        runTracking(reset: false)
        phase = alignment == nil ? .tapA : .placing
        hint = nil
    }

    func startScan() {
        guard alignment != nil else { return }
        tablesSeen = 0
        hint = nil
        scanner.onTablesSeen = { [weak self] n in self?.tablesSeen = n }
        scanner.onInstruction = { [weak self] text in self?.hint = text }
        scanner.onFinished = { [weak self] result in self?.scanFinished(result) }
        scanner.start(on: arView.session)
        phase = .scanning
    }

    func finishScan() {
        phase = .processing
        hint = nil
        scanner.finish()
    }

    private func scanFinished(_ result: Result<[CapturedRoom.Object], Error>) {
        runTracking(reset: false)
        guard let alignment else { phase = .tapA; return }
        switch result {
        case .success(let objects):
            let detected = RoomScanController.detectedObjects(objects, alignment: alignment)
            deliver(ReportBuilder.roomScan(layout: layout, detected: detected, settings: settings))
        case .failure(let error):
            phase = .scanReady
            hint = "The scan stopped: \(error.localizedDescription) Try again."
        }
    }

    /// Point-and-check: the table under the center reticle.
    func checkCenter() {
        guard let alignment else { return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal).first
            ?? arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal).first
        guard let t = hit?.worldTransform else {
            lastPointResult = "Couldn't see a surface there. Aim at the middle of a table."
            return
        }
        let world = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        let p = alignment.plan(world)
        guard let table = ReportBuilder.nearestTable(to: p, in: layout, settings: settings) else {
            lastPointResult = "No table in the plan near that spot."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        pointChecks.append(p)
        let offset = p - table.center
        let result = TableResult(itemID: table.id, status: offset.length <= settings.toleranceFt ? .enPlace : .off, offset: offset)
        lastPointResult = Wording(layout: layout).message(for: result)
        ghosts[table.id]?.model?.materials = [GhostFactory.material(result.status == .enPlace ? .enPlace : .off)]
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    var pointCheckedCount: Int {
        Set(pointChecks.compactMap { ReportBuilder.nearestTable(to: $0, in: layout, settings: settings)?.id }).count
    }

    func finishPointCheck() {
        deliver(ReportBuilder.pointCheck(layout: layout, checks: pointChecks, settings: settings))
    }

    private func deliver(_ r: CheckReport) {
        report = r
        fixedSinceReport = []
        phase = .placing
        refreshAllAppearances()
        onReport?(r)
        presentingReport = true
        UINotificationFeedbackGenerator().notificationOccurred(r.isClean ? .success : .warning)
    }

    // MARK: Focus from the report

    func focus(on issue: IssueRef) {
        clearFocus()
        focus = issue
        guard let anchor = layoutAnchor, let a = alignment else { return }
        let origin = a.planA
        switch issue {
        case .table(let id):
            refreshAppearance(id)
        case .extra(let i):
            guard let extra = report?.extras[safe: i] else { return }
            let f = extra.footprint
            let box = ModelEntity(mesh: .generateBox(size: [Float(Units.meters(f.length)), GhostFactory.tableHeight, Float(Units.meters(f.width))]),
                                  materials: [GhostFactory.material(.off)])
            let local = (f.center - origin) * Units.metersPerFoot
            box.position = [Float(local.x), GhostFactory.tableHeight / 2, Float(local.y)]
            box.orientation = simd_quatf(angle: -Float(f.rotationDegrees * .pi / 180), axis: [0, 1, 0])
            anchor.addChild(box)
            focusEntity = box
        case .aisle(let id):
            guard let aisle = layout.aisles.first(where: { $0.id == id }),
                  let result = report?.aisles.first(where: { $0.aisleID == id }) else { return }
            let marker = Entity()
            let strip = GhostFactory.makeAisle(aisle, origin: origin)
            strip.model?.materials = [GhostFactory.translucent(Palette.Fixed.terracotta, opacity: 0.45)]
            strip.position.y += 0.002
            marker.addChild(strip)
            let post = ModelEntity(mesh: GhostFactory.cylinder(radius: 0.03, height: 1.2),
                                   materials: [GhostFactory.material(.highlight)])
            let local = (result.narrowestAt - origin) * Units.metersPerFoot
            post.position = [Float(local.x), 0.6, Float(local.y)]
            marker.addChild(post)
            anchor.addChild(marker)
            focusEntity = marker
        }
    }

    func clearFocus() {
        let old = focus
        focus = nil
        focusEntity?.removeFromParent()
        focusEntity = nil
        if case .table(let id) = old { refreshAppearance(id) }
    }

    var focusText: String? {
        guard let focus, let report else { return nil }
        let w = Wording(layout: layout)
        switch focus {
        case .table(let id):
            return report.tables.first { $0.itemID == id }.map(w.message(for:))
        case .extra(let i):
            return report.extras[safe: i].map(w.message(for:))
        case .aisle(let id):
            return report.aisles.first { $0.aisleID == id }.map(w.message(for:))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
