import SwiftUI
import MisescaKit

struct PlanScreen: View {
    @Environment(EventStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var eventID: UUID

    @State private var setting = false
    @State private var confirmReset = false

    var body: some View {
        if let event = store.event(eventID) {
            content(event)
        } else {
            Text("This event is no longer on this iPhone.")
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.background)
        }
    }

    private func content(_ event: EventRecord) -> some View {
        let layout = event.layout
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(details(layout))
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                    StatusLabel(status: event.status)
                }

                PlanCanvasView(layout: layout, placed: Set(event.placed))
                    .frame(maxWidth: .infinity)

                CountsGrid(layout: layout)

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Line-up points")
                    ReferenceRow(letter: "A", point: layout.referencePoints.a)
                    ReferenceRow(letter: "B", point: layout.referencePoints.b)
                    Text("In Set Mode you'll tap these two spots on the real floor.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Setup")
                    if event.placedCount > 0 {
                        Text("\(event.placedCount) of \(event.totalCount) en place")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.ink)
                        ProgressLine(done: event.placedCount, total: event.totalCount)
                    }
                    NavigationLink {
                        MarkOnPlanView(eventID: eventID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Mark on plan")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.ink)
                                Text("Without the camera, from the plan or a list.")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Palette.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                }

                if let report = event.lastReport {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Last check")
                        NavigationLink {
                            ReportView(layout: layout, report: report)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.isClean ? "Room's set. Everything in its place." : report.summary)
                                        .font(.body.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(report.isClean ? Palette.sage : Palette.ink)
                                        .multilineTextAlignment(.leading)
                                    Text(Format.checkTime.string(from: report.date))
                                        .font(.footnote)
                                        .foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Palette.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Palette.background)
        .navigationTitle(layout.event.name)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button(event.placedCount == 0 ? "Start setting" : "Keep setting") { setting = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.background)
        }
        .toolbar {
            if event.placedCount > 0 || event.lastReport != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear setup and checks", role: .destructive) { confirmReset = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Clear setup and checks?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                store.update(eventID) {
                    $0.placed = []
                    $0.lastReport = nil
                }
            }
        } message: {
            Text("Every item goes back to not set, and the last check is removed.")
        }
        .fullScreenCover(isPresented: $setting) {
            SetModeView(eventID: eventID)
        }
    }

    private func details(_ layout: EventLayout) -> String {
        var parts = [layout.event.room]
        if let start = layout.event.start { parts.append(Format.eventDate.string(from: start)) }
        if let g = layout.event.guests { parts.append("\(g) guests") }
        return parts.joined(separator: " · ")
    }
}

struct CountsGrid: View {
    var layout: EventLayout

    var body: some View {
        let c = layout.counts
        let rows: [(String, String)] = [
            ("Rounds", "\(c.rounds)"),
            ("Banquet tables", "\(c.banquetTables)"),
            ("Oval tables", "\(c.ovalTables)"),
            ("Stage", "\(c.stages)"),
            ("Bar", "\(c.bars)"),
            ("Dance floor", "\(c.danceFloors)"),
            ("Seats", "\(c.seats)"),
            ("Room", "\(feet(layout.room.widthFt)) × \(feet(layout.room.depthFt)) ft")
        ]
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Counts")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0).foregroundStyle(Palette.secondary)
                        Spacer()
                        Text(row.1)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(Palette.ink)
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if i < rows.count - 1 {
                        Divider().overlay(Palette.rule)
                    }
                }
            }
        }
    }

    private func feet(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

struct ReferenceRow: View {
    var letter: String
    var point: ReferencePoint

    var body: some View {
        HStack(spacing: 12) {
            ReferenceBadge(letter: letter)
            Text(point.label)
                .font(.body)
                .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
