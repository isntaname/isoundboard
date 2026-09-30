import Foundation
import Security

/// Whether the audio driver bundled in the app is installed, and matches.
public enum DriverStatus: Equatable, Sendable {
    /// This build of the app carries no driver (e.g. a bare SwiftPM build).
    case unavailable
    case notInstalled
    case current
    /// Installed, but not the version this app carries.
    case outdated
}

/// Installs the virtual audio device the game records from: our build of
/// BlackHole, named iSoundboard. See docs/design/driver-install.md.
public enum DriverInstaller {
    public static let deviceUID = "iSoundboard_UID"
    /// People who installed BlackHole themselves keep using it.
    public static let blackHoleUID = "BlackHole2ch_UID"
    public static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/iSoundboard.driver")
    public static let prompt = "iSoundboard needs your password to install its audio driver."

    public enum Outcome: Equatable, Sendable {
        case done
        /// The user clicked Cancel in the password prompt.
        case cancelled
        case failed(String)
    }

    public static var bundledURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Driver/iSoundboard.driver")
    }

    public static func status(installedVersion: String?, bundledVersion: String?) -> DriverStatus {
        guard let bundledVersion else { return .unavailable }
        guard let installedVersion else { return .notInstalled }
        return installedVersion == bundledVersion ? .current : .outdated
    }

    /// Read from the plist directly: `Bundle(url:)` caches, and the installed
    /// copy changes underneath a running app.
    public static func version(ofDriverAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return nil }
        return info["CFBundleVersion"] as? String ?? ""
    }

    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func appleScriptString(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "\"", with: #"\""#)
        return "\"" + escaped + "\""
    }

    /// The bundled driver sits in the user-writable app bundle, so anything
    /// running as the user could swap it while the password prompt is up. Root
    /// therefore copies it somewhere only root can write, checks the signature
    /// there, and only then replaces the installed copy. A failed check leaves
    /// the old driver in place.
    public static func installCommand(bundled: URL, installed: URL = installedURL,
                                      requirement: String) -> String {
        let stage = #""$T"/iSoundboard.driver"#
        let target = shellQuote(installed.path)
        return "T=$(mktemp -d) && ditto \(shellQuote(bundled.path)) \(stage) && [ ! -L \(stage) ]"
            + " && codesign --verify --strict -R=\(shellQuote(requirement)) \(stage)"
            + " && xattr -cr \(stage) && chown -R root:wheel \(stage)"
            + " && rm -rf \(target) && mv \(stage) \(target) && rm -rf \"$T\" && killall coreaudiod"
    }

    /// The code requirement the driver must meet: our bundle id, signed by the
    /// same team as the running app. Ad-hoc development builds have no team.
    public static func requirement(teamID: String?) -> String {
        let identifier = #"identifier "io.github.isntaname.isoundboard.driver""#
        guard let teamID else { return identifier }
        return #"anchor apple generic and \#(identifier) and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    /// The running app's signing team, read from its in-memory signature, so a
    /// modified bundle on disk can't change it.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether Settings offers Install/Update. Stays up while installing and
    /// while there is an error to show, or the error would have nowhere to go.
    public static func offersInstall(status: DriverStatus, usesOurDriver: Bool, hasVirtualDevice: Bool,
                                     isChanging: Bool, hasError: Bool) -> Bool {
        guard status != .unavailable else { return false }
        if status == .notInstalled || !hasVirtualDevice || isChanging || hasError { return true }
        return usesOurDriver && status == .outdated
    }

    public static func uninstallCommand(installed: URL = installedURL) -> String {
        "rm -rf \(shellQuote(installed.path)) && killall coreaudiod"
    }

    public static func outcome(errorNumber: Int?, message: String?) -> Outcome {
        guard let errorNumber else { return .done }
        if errorNumber == -128 { return .cancelled }
        return .failed(message ?? "The audio driver could not be installed.")
    }

    /// Runs `command` as root after the system password prompt. Blocks while
    /// the prompt is up, which is what the user is looking at anyway.
    @MainActor
    public static func runPrivileged(_ command: String) -> Outcome {
        let source = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return outcome(errorNumber: error?[NSAppleScript.errorNumber] as? Int,
                       message: error?[NSAppleScript.errorMessage] as? String)
    }
}
