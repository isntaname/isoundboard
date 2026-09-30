import AVFoundation
import Foundation
import InputControl

/// One soundboard entry. Codable so the board survives a relaunch.
struct Sound: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    var hotkey: Hotkey?
    var gain: Float = 1.0
    /// Read once when the sound is added. The game's mic closes when you let go
    /// of push-to-talk, so knowing the length is how you know how long to hold.
    var duration: TimeInterval?

    init(url: URL) {
        self.name = url.deletingPathExtension().lastPathComponent
        self.url = url
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            duration = Double(file.length) / file.fileFormat.sampleRate
        }
    }

    var durationText: String {
        guard let duration else { return "" }
        return duration < 10
            ? String(format: "%.1fs", duration)
            : String(format: "%.0fs", duration)
    }
}

/// Persists the board to Application Support.
enum Library {
    static var fileURL: URL {
        return AppFolder.file("library.json")
    }

    static func load() -> [Sound] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Sound].self, from: data)) ?? []
    }

    static func save(_ sounds: [Sound]) {
        guard let data = try? JSONEncoder().encode(sounds) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
