import AudioEngine
import InputControl
import SoundboardCore
import SwiftUI

// MARK: - Short copy
//
// The core types carry longer descriptions for docs and the CLI. The window
// uses these tighter versions.

extension MicrophoneMode {
    var shortLabel: String {
        switch self {
        case .muted: return "Muted"
        case .always: return "Always mixed in"
        case .whenIdle: return "Muted while a clip plays"
        }
    }
}

extension SetupRequirement {
    var shortDetail: String {
        switch self {
        case .virtualDevice: return "The game hears iSoundboard through it."
        case .audioRunning: return "Check the devices under Audio in Settings."
        case .inputMonitoring: return "Hotkeys won't reach the app while a game is focused."
        case .microphone: return "Or set Your voice to Muted in Settings."
        }
    }
}

// MARK: - Settings

/// Install or Update, with progress and any error. Shared by the setup screen
/// and Settings.
struct DriverInstallButton: View {
    @Bindable var model: AppModel
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                button
                if model.isChangingDriver { ProgressView().controlSize(.small) }
            }
            if let error = model.driverError {
                Caption(error, warning: true).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var button: some View {
        let title = model.driverStatus == .outdated ? "Update Audio Driver" : "Install Audio Driver"
        if prominent {
            Button(title) { Task { await model.installDriver() } }
                .buttonStyle(.borderedProminent)
                .tint(Palette.lit)
                .foregroundStyle(Palette.litInk)
                .disabled(model.isChangingDriver)
        } else {
            Button(title) { Task { await model.installDriver() } }
                .disabled(model.isChangingDriver)
        }
    }
}

struct AudioSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Your microphone") {
            Picker("Device", selection: $model.microphoneUID) {
                Text("System Default\(model.defaultInputName)").tag(String?.none)
                Divider()
                ForEach(model.selectableMicrophones, id: \.uid) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            Picker("Your voice", selection: $model.micMode) {
                ForEach(MicrophoneMode.allCases, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            if let warning = model.lowQualityWarning {
                Caption(warning, warning: true)
            }
        }

        Section("What the game hears") {
            HStack(spacing: 8) {
                StatusLED(state: model.virtualDevice != nil ? .on : .warn)
                Text(model.virtualDevice?.name ?? "No audio driver installed")
                Spacer()
                Button("Refresh Devices") { model.refreshDevices(); model.ensureRunning() }
            }
            // Offered even to BlackHole users, so they can switch; only the
            // setup screen stays quiet for them.
            if model.offersDriverInstall {
                DriverInstallButton(model: model)
            }
            Toggle("Make it the system microphone", isOn: $model.claimSystemMicrophone)
            if model.claimSystemMicrophone {
                Caption("Your previous microphone comes back when you quit.")
            } else if let name = model.virtualDevice?.name {
                Caption("Choose \(name) as the voice input in your game.")
            }
            if model.usesOurDriver {
                Button("Uninstall Audio Driver", role: .destructive) {
                    Task { await model.uninstallDriver() }
                }
                .buttonStyle(.link)
                .disabled(model.isChangingDriver)
            }
        }

        Section("What you hear") {
            Toggle("Hear clips yourself", isOn: Binding(
                get: { model.monitorEnabled },
                set: { model.setMonitoring($0) }))
            Picker("Output", selection: Binding(
                get: { model.monitorDeviceUID },
                set: { model.monitorDeviceUID = $0; model.monitorDeviceChanged() })) {
                    Text("System Default\(model.defaultOutputName)").tag(String?.none)
                    Divider()
                    ForEach(model.selectableOutputs, id: \.uid) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .disabled(!model.monitorEnabled)
            LabeledContent("Volume") {
                HStack {
                    Slider(value: $model.monitorVolume, in: 0...1)
                    Text("\(Int(model.monitorVolume * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!model.monitorEnabled)
        }
    }
}

struct PushToTalkSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Push-to-talk emulation") {
            // Named for what it does: the app presses the game's own
            // push-to-talk key for you, not a setting for your own talking.
            Toggle("Emulate push-to-talk while a clip plays", isOn: $model.pttEnabled)
            LabeledContent("Game's push-to-talk key") {
                HStack(spacing: 8) {
                    if model.pttActive {
                        HStack(spacing: 5) {
                            StatusLED(state: .on)
                            Text("Holding").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    KeyCap(hotkey: model.pttTrigger.name,
                           recording: model.recordingPTTKey) {
                        model.recordingPTTKey = true
                    }
                }
            }
            .disabled(!model.pttEnabled)
        }
    }
}

struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Permissions") {
            if model.launchedFromTerminal {
                Caption("Started from a terminal, so these show the terminal's permissions. Relaunch with open build/iSoundboard.app.",
                        warning: true)
            }

            ForEach(Permission.allCases, id: \.self) { permission in
                let granted = model.isGranted(permission)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(granted ? Palette.ledGreen : Palette.ledAmber)
                        .accessibilityLabel(granted ? "Granted" : "Not granted")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.rawValue)
                        if !granted {
                            Text(permission.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !granted && permission == .inputMonitoring {
                            Button("Show iSoundboard.app in Finder") { model.revealAppInFinder() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    Spacer()
                    if !granted {
                        if permission.canPrompt {
                            Button("Ask") { model.requestPermission(permission) }
                        }
                        Button("Open System Settings") { permission.openSettings() }
                    }
                }
            }

            HStack(spacing: 10) {
                StatusLED(state: model.keyboardWorking ? .on : .warn)
                Text(model.keyboardWorking ? "Hotkeys working" : "Hotkeys not received yet")
                Spacer()
                Button("Relaunch") { model.relaunch() }
            }

            if model.hasStaleAuthorization {
                Caption("After a rebuild the old approval stops matching: remove iSoundboard from Input Monitoring, then add it again.",
                        warning: true)
            }
        }
    }
}

/// A one-line note under a setting.
struct Caption: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            if warning { Image(systemName: "exclamationmark.triangle.fill") }
        }
        .labelStyle(CaptionLabelStyle(showIcon: warning))
        .font(.caption)
        .foregroundStyle(warning ? AnyShapeStyle(Palette.ledAmber) : AnyShapeStyle(.secondary))
    }
}

private struct CaptionLabelStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}

// MARK: - Setup gate

/// Shown in place of the pads until the app is configured. Lists exactly
/// what is missing, so the next step is always obvious.
struct SetupNeededView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void

    private var status: SetupStatus { model.setupStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Finish setup first")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(status.unmet, id: \.self) { requirement in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        StatusLED(state: .warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(requirement.title).fontWeight(.medium)
                            Text(requirement.shortDetail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if requirement == .virtualDevice, model.driverStatus != .unavailable {
                                DriverInstallButton(model: model, prominent: true)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
            }

            Button("Go to Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .tint(Palette.lit)
                .foregroundStyle(Palette.litInk)

            Spacer()
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Root

enum AppTab: String, Hashable {
    case soundboard, settings
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var tab: AppTab
    @AppStorage("selectedTab") private var storedTab = AppTab.soundboard.rawValue

    init(model: AppModel) {
        self.model = model
        // Until setup is done nothing works, so land on Settings; otherwise
        // come back to whichever tab was open last.
        let stored = UserDefaults.standard.string(forKey: "selectedTab").flatMap(AppTab.init) ?? .soundboard
        _tab = State(initialValue: model.setupStatus.isReady ? stored : .settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            transport
            Divider()

            switch tab {
            case .soundboard:
                if model.setupStatus.isReady {
                    PadBoard(model: model)
                } else {
                    SetupNeededView(model: model) { tab = .settings }
                }
            case .settings:
                Form {
                    AudioSettings(model: model)
                    PushToTalkSettings(model: model)
                    PermissionSettings(model: model)
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Pads").tag(AppTab.soundboard)
                    Text("Settings").tag(AppTab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
        }
        .onChange(of: tab) { _, new in storedTab = new.rawValue }
    }

    private var statusText: String {
        guard model.setupStatus.isReady else { return "Setup incomplete" }
        guard model.isRunning else { return model.status }
        if model.micMode != .muted && !model.isGranted(.microphone) {
            return "Live, without your microphone"
        }
        return "Live on \(model.virtualDevice?.name ?? "virtual mic")"
    }

    /// The strip across the top: status, live meters and a stop button, like
    /// the transport section of a mixer. Visible on both tabs.
    private var transport: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    StatusLED(state: model.setupStatus.isReady && model.isRunning ? .on : .warn)
                    Text(statusText)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                if model.micMode != .muted {
                    LEDMeter(label: "Mic", level: model.micLevel)
                }
                LEDMeter(label: "Game", level: model.outputLevel)

                Button {
                    model.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop playback (⌘.)")
            }

            if let error = model.lastError {
                Caption(error, warning: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
