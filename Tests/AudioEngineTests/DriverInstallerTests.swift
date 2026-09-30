import Foundation
import Testing
@testable import AudioEngine

@Suite("DriverInstaller")
struct DriverInstallerTests {

    @Test("no driver inside the app means nothing to install")
    func unavailable() {
        #expect(DriverInstaller.status(installedVersion: nil, bundledVersion: nil) == .unavailable)
        #expect(DriverInstaller.status(installedVersion: "0.7.1.1", bundledVersion: nil) == .unavailable)
    }

    @Test("not installed")
    func notInstalled() {
        #expect(DriverInstaller.status(installedVersion: nil, bundledVersion: "0.7.1.1") == .notInstalled)
    }

    @Test("same version is current")
    func current() {
        #expect(DriverInstaller.status(installedVersion: "0.7.1.1", bundledVersion: "0.7.1.1") == .current)
    }

    @Test("any different version is outdated, including a newer one")
    func outdated() {
        // Going back to an older app should put its driver back too.
        #expect(DriverInstaller.status(installedVersion: "0.7.1.1", bundledVersion: "0.7.1.2") == .outdated)
        #expect(DriverInstaller.status(installedVersion: "0.7.1.3", bundledVersion: "0.7.1.2") == .outdated)
    }

    @Test("an installed driver without a version is outdated")
    func installedWithoutVersion() {
        #expect(DriverInstaller.status(installedVersion: "", bundledVersion: "0.7.1.1") == .outdated)
    }

    @Test("shell quoting survives spaces and apostrophes")
    func shellQuote() {
        #expect(DriverInstaller.shellQuote("/Apps/My Apps/x") == "'/Apps/My Apps/x'")
        #expect(DriverInstaller.shellQuote("/Users/o'neil") == #"'/Users/o'\''neil'"#)
    }

    @Test("AppleScript strings escape quotes and backslashes")
    func appleScriptString() {
        #expect(DriverInstaller.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test("install stages a root-owned copy, verifies its signature, then swaps it in")
    func installCommand() {
        // Copying straight from the user-writable app bundle would let anything
        // running as the user swap the driver between the prompt and the copy.
        let command = DriverInstaller.installCommand(
            bundled: URL(fileURLWithPath: "/Users/o'neil/My Apps/iSoundboard.app/Contents/Library/Driver/iSoundboard.driver"),
            installed: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/iSoundboard.driver"),
            requirement: #"identifier "x""#)
        let source = #"'/Users/o'\''neil/My Apps/iSoundboard.app/Contents/Library/Driver/iSoundboard.driver'"#
        let stage = #""$T"/iSoundboard.driver"#
        let target = "'/Library/Audio/Plug-Ins/HAL/iSoundboard.driver'"
        #expect(command == "T=$(mktemp -d) && ditto \(source) \(stage) && [ ! -L \(stage) ]"
            + " && codesign --verify --strict -R='identifier \"x\"' \(stage)"
            + " && xattr -cr \(stage) && chown -R root:wheel \(stage)"
            + " && rm -rf \(target) && mv \(stage) \(target) && rm -rf \"$T\" && killall coreaudiod")
    }

    @Test("the driver must be signed by the same team as the running app")
    func requirement() {
        #expect(DriverInstaller.requirement(teamID: "A75X33J2VH")
            == #"anchor apple generic and identifier "io.github.isntaname.isoundboard.driver" and certificate leaf[subject.OU] = "A75X33J2VH""#)
        // Ad-hoc development builds have no team to pin.
        #expect(DriverInstaller.requirement(teamID: nil)
            == #"identifier "io.github.isntaname.isoundboard.driver""#)
    }

    @Test("Settings keeps the install button, and its error, until the device is up")
    func offersInstall() {
        func offers(_ status: DriverStatus, ours: Bool = false, device: Bool = true,
                    changing: Bool = false, error: Bool = false) -> Bool {
            DriverInstaller.offersInstall(status: status, usesOurDriver: ours, hasVirtualDevice: device,
                                          isChanging: changing, hasError: error)
        }
        #expect(offers(.notInstalled))                         // BlackHole user can switch
        #expect(offers(.current, device: false, error: true)) // installed, never loaded
        #expect(offers(.current, device: false, changing: true))
        #expect(offers(.current, device: false))              // installed, not loaded: retry
        #expect(offers(.outdated, ours: true))
        #expect(!offers(.current, ours: true))
        #expect(!offers(.outdated, ours: false))               // on BlackHole: don't nag
        #expect(!offers(.unavailable, device: false))
    }

    @Test("uninstall removes and restarts Core Audio")
    func uninstallCommand() {
        let command = DriverInstaller.uninstallCommand(installed: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/iSoundboard.driver"))
        #expect(command == "rm -rf '/Library/Audio/Plug-Ins/HAL/iSoundboard.driver' && killall coreaudiod")
    }

    @Test("clicking Cancel in the password prompt is not an error")
    func cancelled() {
        #expect(DriverInstaller.outcome(errorNumber: -128, message: "User canceled.") == .cancelled)
        #expect(DriverInstaller.outcome(errorNumber: nil, message: nil) == .done)
        #expect(DriverInstaller.outcome(errorNumber: 1, message: "cp: denied") == .failed("cp: denied"))
        #expect(DriverInstaller.outcome(errorNumber: 1, message: nil) == .failed("The audio driver could not be installed."))
    }

    @Test("reads CFBundleVersion from a driver bundle")
    func readsVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = dir.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "0.7.1.1"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(DriverInstaller.version(ofDriverAt: dir) == "0.7.1.1")
        #expect(DriverInstaller.version(ofDriverAt: dir.appendingPathComponent("missing")) == nil)
        try? FileManager.default.removeItem(at: dir)
    }
}
