import SwiftUI
import RealityKit
import MisescaKit

struct SetModeView: View {
    @Environment(EventStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var eventID: UUID

    @State private var session: SetSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                SetModeContent(session: session, close: close)
            }
        }
        .onAppear {
            guard session == nil, let event = store.event(eventID) else { return }
            let tolerance = UserDefaults.standard.object(forKey: Settings.toleranceKey) as? Double ?? Settings.defaultTolerance
            let s = SetSession(layout: event.layout, placed: event.placed, toleranceInches: tolerance)
            s.onPlacedChanged = { placed in
                store.update(eventID) { $0.placed = placed }
            }
            s.onReport = { report in
                store.update(eventID) { $0.lastReport = report }
            }
            session = s
            s.start()
        }
        .onDisappear { session?.stop() }
        .statusBarHidden()
    }

    private func close() {
        session?.stop()
        dismiss()
    }
}

private struct ARViewContainer: UIViewRepresentable {
    var arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

private struct SetModeContent: View {
    @Bindable var session: SetSession
    var close: () -> Void

    private var layout: EventLayout { session.layout }

    var body: some View {
        ZStack {
            ARViewContainer(arView: session.arView)
                .ignoresSafeArea()

            if session.phase == .pointCheck {
                Reticle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                panel
            }
        }
        .sheet(isPresented: $session.presentingReport) {
            if let report = session.report {
                NavigationStack {
                    ReportView(layout: layout, report: report) { issue in
                        session.presentingReport = false
                        session.focus(on: issue)
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Back to room") { session.presentingReport = false }
                        }
                    }
                }
            }
        }
    }

    // MARK: Top bar

    private var title: String {
        switch session.phase {
        case .scanReady, .scanning, .processing, .pointCheck: return "Mise Check"
        default: return "Set Mode"
        }
    }

    private var topBar: some View {
        HStack {
            OverlayButton(systemImage: "xmark", label: "Close", action: close)
            Spacer()
            Text(title)
                .font(.heading(.headline))
                .foregroundStyle(Palette.Fixed.linen.swiftUI)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.Fixed.ink.swiftUI.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            Spacer()
            if session.isAligned, session.phase == .placing {
                OverlayButton(systemImage: "scope", label: "Line up again", action: session.realign)
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Bottom panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .padding(.bottom, 4)
        .background(Palette.background, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.2), value: session.phase)
    }

    @ViewBuilder
    private var panelContent: some View {
        let a = layout.referencePoints.a, b = layout.referencePoints.b
        switch session.phase {
        case .unsupported:
            PanelTitle("Set Mode isn't available")
            PanelText("This iPhone can't track the room in AR. Use an iPhone XS or newer.")
            Button("Close", action: close).buttonStyle(PrimaryButtonStyle())

        case .cameraDenied:
            PanelTitle("Camera access is off")
            PanelText("Set Mode uses the camera to find the floor and show the layout on it. Turn on camera access for Misesca in Settings.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Close", action: close).buttonStyle(SecondaryButtonStyle())

        case .findingFloor:
            PanelTitle("Find the floor")
            PanelText(session.hint ?? "Point at the floor and move slowly.")

        case .tapA:
            HStack(spacing: 10) {
                ReferenceBadge(letter: "A")
                PanelTitle("Tap the \(lowercasedFirst(a.label)).")
            }
            if let notice = session.notice {
                PanelText(notice, color: Palette.terracotta)
            }
            PanelText(session.hint ?? "Stand where you can see the spot, then tap it on the floor.")

        case .tapB:
            HStack(spacing: 10) {
                ReferenceBadge(letter: "B")
                PanelTitle("Now tap the \(lowercasedFirst(b.label)).")
            }
            if let hint = session.hint { PanelText(hint) }
            Button("Redo point A", action: session.redoPoints).buttonStyle(SecondaryButtonStyle())

        case .mismatch(let check):
            PanelTitle("Points don't match the plan")
            PanelText(check.message ?? "")
            Button("Redo points", action: session.redoPoints).buttonStyle(PrimaryButtonStyle())
            Button("Use these points", action: session.acceptMismatch).buttonStyle(SecondaryButtonStyle())

        case .placing:
            placingContent

        case .scanReady:
            PanelTitle("Scan the room")
            PanelText(session.hint ?? "Walk the whole room slowly with the phone at chest height. Point it at every table.")
            Button("Start scan", action: session.startScan).buttonStyle(PrimaryButtonStyle())
            Button("Back", action: session.cancelCheck).buttonStyle(SecondaryButtonStyle())

        case .scanning:
            HStack(alignment: .firstTextBaseline) {
                PanelTitle("Scanning")
                Spacer()
                Text("\(session.tablesSeen) tables seen")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
            PanelText(session.hint ?? "Keep walking. Get every table in view once.")
            Button("Finish scan", action: session.finishScan).buttonStyle(PrimaryButtonStyle())
            Button("Cancel", action: session.cancelCheck).buttonStyle(SecondaryButtonStyle())

        case .processing:
            HStack(spacing: 12) {
                ProgressView()
                PanelTitle("Comparing the room to the plan")
            }

        case .pointCheck:
            PanelTitle("Check tables one at a time")
            PanelText(session.lastPointResult ?? "Aim the center mark at the middle of a table, then tap Check table.")
            Text("Room scanning needs an iPhone with LiDAR. Aisle widths aren't checked this way.")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
            Button("Check table", action: session.checkCenter).buttonStyle(PrimaryButtonStyle())
            HStack(spacing: 12) {
                Button("Back", action: session.cancelCheck).buttonStyle(SecondaryButtonStyle())
                Button("See report (\(session.pointCheckedCount))", action: session.finishPointCheck)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(session.pointCheckedCount == 0)
                    .opacity(session.pointCheckedCount == 0 ? 0.5 : 1)
            }
        }
    }

    @ViewBuilder
    private var placingContent: some View {
        if let text = session.focusText {
            PanelText(text)
                .font(.body.weight(.semibold))
            HStack(spacing: 12) {
                Button("Done", action: session.clearFocus).buttonStyle(SecondaryButtonStyle())
                Button("Report") { session.presentingReport = true }.buttonStyle(SecondaryButtonStyle())
            }
        } else {
            let total = layout.items.count
            HStack(alignment: .firstTextBaseline) {
                Text("\(session.placedCount) of \(total) en place")
                    .font(.heading(.title3))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                Spacer()
                if session.report != nil {
                    Button("Report") { session.presentingReport = true }
                        .font(.body.weight(.semibold))
                }
            }
            ProgressLine(done: session.placedCount, total: total)
            PanelText(session.hint ?? (session.placedCount == total
                ? "Everything is marked. Run Mise Check before doors."
                : "Set each table on its outline, then tap it."))
            HStack(spacing: 12) {
                Button {
                    session.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(session.placed.isEmpty)
                .opacity(session.placed.isEmpty ? 0.5 : 1)

                Button("Mise Check", action: session.beginCheck)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }
}

private struct PanelTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.heading(.title3))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PanelText: View {
    var text: String
    var color: Color
    init(_ text: String, color: Color = Palette.secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OverlayButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.Fixed.linen.swiftUI)
                .frame(width: 48, height: 48)
                .background(Palette.Fixed.ink.swiftUI.opacity(0.75), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Center mark for point-and-check.
private struct Reticle: View {
    var body: some View {
        ZStack {
            Circle().stroke(Palette.Fixed.linen.swiftUI, lineWidth: 2).frame(width: 44, height: 44)
            Circle().stroke(Palette.Fixed.ink.swiftUI.opacity(0.6), lineWidth: 1).frame(width: 48, height: 48)
            Circle().fill(Palette.Fixed.brass.swiftUI).frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }
}

extension UIColor {
    var swiftUI: Color { Color(self) }
}
