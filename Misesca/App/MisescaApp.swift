import SwiftUI
import MisescaKit

@main
struct MisescaApp: App {
    @State private var store = EventStore()
    @State private var path: [UUID] = []
    @State private var importError: String?
    @AppStorage(Settings.introKey) private var hasSeenIntro = false

    init() {
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                EventsListView(path: $path)
                    .navigationDestination(for: UUID.self) { id in
                        PlanScreen(eventID: id)
                    }
            }
            .environment(store)
            .tint(Palette.brass)
            .fullScreenCover(isPresented: Binding(get: { !hasSeenIntro }, set: { hasSeenIntro = !$0 })) {
                IntroView { hasSeenIntro = true }
            }
            // A layout file opened from Files, Mail or the share sheet.
            .onOpenURL { url in
                do {
                    let record = try store.importLayout(from: url)
                    path = [record.id]
                } catch {
                    importError = error.localizedDescription
                }
            }
            .alert("Couldn't import layout", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }
}
