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
