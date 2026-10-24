import SwiftUI
import UniformTypeIdentifiers
import MisescaKit

struct EventsListView: View {
    @Environment(EventStore.self) private var store
    @Binding var path: [UUID]

    @State private var importing = false
    @State private var importError: String?
    @State private var showingSettings = false
    @State private var pendingDelete: EventRecord?

    var body: some View {
        Group {
            if store.events.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.events) { event in
                        NavigationLink(value: event.id) {
                            EventRow(event: event)
                        }
                        .listRowBackground(Palette.background)
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = event }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.background)
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: {
                    Label("Import layout", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    let record = try store.importLayout(from: url)
                    path.append(record.id)
                } catch {
                    importError = error.localizedDescription
                }
            case .failure:
                importError = "Couldn't open that file."
            }
        }
        .alert("Couldn't import layout", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("Couldn't save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.saveError ?? "")
        }
        .confirmationDialog(pendingDelete.map { "Delete \($0.layout.event.name)?" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete event", role: .destructive) {
                if let e = pendingDelete { store.delete(e.id) }
            }
        } message: {
            Text("The layout, setup progress and check results will be removed from this iPhone.")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No events on this iPhone")
                .font(.heading(.title2))
                .foregroundStyle(Palette.ink)
            Text("Import a layout file from Files, or add the sample events to try a setup.")
                .font(.body)
                .foregroundStyle(Palette.secondary)
            Button("Import layout") { importing = true }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
            Button("Add sample events") { store.restoreSamples() }
                .buttonStyle(SecondaryButtonStyle())
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct EventRow: View {
    var event: EventRecord

    var body: some View {
        let info = event.layout.event
        VStack(alignment: .leading, spacing: 6) {
            Text(info.name)
                .font(.heading(.title3))
                .foregroundStyle(Palette.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
            HStack(spacing: 12) {
                StatusLabel(status: event.status)
                if event.status == .setting {
                    Text("\(event.placedCount) of \(event.totalCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = [event.layout.event.room]
        if let start = event.layout.event.start { parts.append(Format.eventDate.string(from: start)) }
        let c = event.layout.counts
        if c.rounds >= c.banquetTables {
            parts.append("\(c.rounds) rounds")
        } else {
            parts.append("\(event.layout.tables.count) tables")
        }
        if let guests = event.layout.event.guests { parts.append("\(guests) guests") }
        return parts.joined(separator: " · ")
    }
}
