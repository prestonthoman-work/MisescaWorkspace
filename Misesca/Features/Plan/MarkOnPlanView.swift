import SwiftUI
import MisescaKit

/// Marking without AR: tap pieces on the plan or in the list. Works with VoiceOver,
/// and keeps setup moving if the camera can't line up.
struct MarkOnPlanView: View {
    @Environment(EventStore.self) private var store
    var eventID: UUID

    @State private var planWidth: CGFloat = 0
    @State private var toggles = 0

    var body: some View {
        if let event = store.event(eventID) {
            content(event)
        }
    }

    private func content(_ event: EventRecord) -> some View {
        let layout = event.layout
        let placed = Set(event.placed)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tap a piece on the plan or in the list once it's set. Tap again to take it back.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)

                PlanCanvasView(layout: layout, placed: placed)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { planWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in planWidth = w }
                    })
                    .onTapGesture(coordinateSpace: .local) { location in
                        if let id = item(at: location, in: layout) { toggle(id, in: event) }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("\(event.placedCount) of \(event.totalCount) en place")
                        .font(.heading(.title3))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                    ProgressLine(done: event.placedCount, total: event.totalCount)
                }

                if event.lastReport != nil {
                    Text("The last Mise Check still sets this event's status. Run it again in Set Mode once the room is fixed.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(layout.items) { item in
                        let isPlaced = placed.contains(item.id)
                        Button {
                            toggle(item.id, in: event)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: isPlaced ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 24))
                                    .foregroundStyle(isPlaced ? Palette.sage : Palette.secondary)
                                Text(item.displayName)
                                    .font(.body)
                                    .foregroundStyle(Palette.ink)
                                Spacer()
                                Text(isPlaced ? "En place" : "Not set")
                                    .font(.subheadline)
                                    .foregroundStyle(isPlaced ? Palette.sage : Palette.secondary)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.displayName)
                        .accessibilityValue(isPlaced ? "En place" : "Not set")
                        .accessibilityHint(isPlaced ? "Double tap to mark not set." : "Double tap to mark en place.")
                        Divider().overlay(Palette.rule)
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Mark on plan")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.impact, trigger: toggles)
    }

    /// The piece under a tap. Tables win over the stage or dance floor they sit near,
    /// and a little slack around each piece makes small rounds easy to hit.
    private func item(at location: CGPoint, in layout: EventLayout) -> String? {
        guard planWidth > 0 else { return nil }
        let scale = planWidth / layout.room.widthFt
        let p = PlanPoint(x: location.x / scale, y: location.y / scale)
        let hits = layout.items.filter { $0.footprint.inflated(by: 1).contains(p) }
        let best = hits.sorted {
            if $0.type.isTable != $1.type.isTable { return $0.type.isTable }
            return $0.center.distance(to: p) < $1.center.distance(to: p)
        }.first
        return best?.id
    }

    private func toggle(_ id: String, in event: EventRecord) {
        store.update(eventID) {
            if $0.isPlaced(id) { $0.unmark(id) } else { $0.markPlaced(id) }
        }
        toggles += 1
    }
}
