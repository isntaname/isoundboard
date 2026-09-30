import Foundation

/// The app used to be called Soundboard (bundle id com.soundboard.app), then
/// briefly had a bundle id with a misspelt account name. Carries settings and
/// the sound library over so neither rename loses anything.
enum Migration {
    /// Newest first: where both have a setting, the newer value wins.
    static let oldBundleIDs = ["io.github.isnotaname.isoundboard", "com.soundboard.app"]
    private static let doneKey = "migratedFromSoundboard"

    /// Must run before AppModel is created: its properties read settings on init.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        for oldBundleID in oldBundleIDs {
            guard let old = defaults.persistentDomain(forName: oldBundleID) else { continue }
            // "asked-*" records which permission prompts were shown. The new
            // bundle id has no grants, so it has to ask again.
            for (key, value) in old where !key.hasPrefix("asked-") && key != doneKey
                && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFolder = support.appendingPathComponent("Soundboard", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldFolder.path),
           !FileManager.default.fileExists(atPath: AppFolder.url.path) {
            try? FileManager.default.copyItem(at: oldFolder, to: AppFolder.url)
        }

        defaults.set(true, forKey: doneKey)
    }
}

/// ~/Library/Application Support/iSoundboard
enum AppFolder {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSoundboard", isDirectory: true)
    }

    static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent(name)
    }
}
