import SwiftUI
import RoomPlan
import MisescaKit

struct SettingsView: View {
    @Environment(EventStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.toleranceKey) private var tolerance = Settings.defaultTolerance
    @AppStorage(Settings.introKey) private var hasSeenIntro = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $tolerance, in: 3...36, step: 1) {
                        HStack {
                            Text("Tolerance")
                            Spacer()
                            Text(Format.inches(tolerance))
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                } header: {
                    Text("Mise Check")
                } footer: {
                    Text("A table within this distance of its spot on the plan counts as en place.")
                }

                Section("This iPhone") {
                    if RoomCaptureSession.isSupported {
                        Label("Room scanning is available.", systemImage: "checkmark")
                    } else {
                        Text("Room scanning needs an iPhone with LiDAR. You can still check tables one at a time.")
                    }
                }

                if let sample = Bundle.main.url(forResource: "demo-room", withExtension: "json") {
                    Section {
                        ShareLink(item: sample) {
                            Label("Save a sample layout file", systemImage: "square.and.arrow.up")
                        }
                        if let diagram = Bundle.main.url(forResource: "harbor-diagram", withExtension: "png") {
                            ShareLink(item: diagram) {
                                Label("Save a sample diagram image", systemImage: "square.and.arrow.up")
                            }
                        }
                    } header: {
                        Text("Layout files")
                    } footer: {
                        Text("Import a .json layout file, or a diagram as an image or PDF. From a diagram you mark the room size and line-up points and check each table before saving.")
                    }
                }

                Section("Privacy") {
                    Text("Everything stays on this iPhone. The camera is used only in Set Mode, to find the floor and the tables. Misesca doesn't record video or look at people.")
                        .foregroundStyle(Palette.secondary)
                }

                Section {
                    Button("Show the intro again") {
                        dismiss()
                        hasSeenIntro = false
                    }
                    Button("Add sample events") {
                        store.restoreSamples()
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
