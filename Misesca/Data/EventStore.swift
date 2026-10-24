import Foundation
import Observation
import UniformTypeIdentifiers
import MisescaKit

/// All events on this iPhone. Saved as one JSON file in Application Support; nothing leaves the device.
@MainActor
@Observable
final class EventStore {
    private(set) var events: [EventRecord] = []
    /// Set when saving fails, so the UI can say so instead of losing work quietly.
    var saveError: String?

    private let fileURL: URL

    static let sampleFiles = ["harbor-room-gala", "demo-room"]

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("events.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? LayoutLoader.decoder().decode([EventRecord].self, from: data) {
            events = saved
        } else {
            events = Self.bundledSamples()
            save()
        }
    }

    static func bundledSamples() -> [EventRecord] {
        sampleFiles.compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let layout = try? LayoutLoader.load(data) else { return nil }
            return EventRecord(layout: layout)
        }
    }

    func event(_ id: UUID) -> EventRecord? { events.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout EventRecord) -> Void) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        change(&events[i])
        save()
    }

    @discardableResult
    func add(_ layout: EventLayout) -> EventRecord {
        let record = EventRecord(layout: layout)
        events.insert(record, at: 0)
        save()
        return record
    }

    func delete(_ id: UUID) {
        events.removeAll { $0.id == id }
        save()
    }

    /// Adds back any sample event that isn't on the phone.
    func restoreSamples() {
        let names = Set(events.map(\.layout.event.name))
        for sample in Self.bundledSamples() where !names.contains(sample.layout.event.name) {
            events.append(sample)
        }
        save()
    }

    /// Reads a layout file from Files or the share sheet. Throws a LayoutError worded for the crew.
    func importLayout(from url: URL) throws -> EventRecord {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) || type.conforms(to: .movie) {
            throw LayoutError("That's a photo, not a layout file. Misesca reads layout files that end in .json, like the samples. It can't read a picture of a floor plan.")
        }
        if let type, type.conforms(to: .pdf) {
            throw LayoutError("That's a PDF. Misesca reads layout files that end in .json, like the samples. It can't read a PDF diagram.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutError("Couldn't open \(url.lastPathComponent).")
        }
        return add(try LayoutLoader.load(data))
    }

    private func save() {
        do {
            let data = try LayoutLoader.encoder().encode(events)
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn't save changes on this iPhone. Free up some storage and try again."
        }
    }
}

enum Settings {
    static let toleranceKey = "toleranceInches"
    static let introKey = "hasSeenIntro"
    static let defaultTolerance = 12.0
}
