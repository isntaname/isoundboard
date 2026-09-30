import Foundation

/// Something that must be true before the soundboard can do its job.
public enum SetupRequirement: String, Sendable, Hashable, CaseIterable {
    case virtualDevice
    case audioRunning
    case inputMonitoring
    case microphone

    public var title: String {
        switch self {
        case .virtualDevice: return "Install the audio driver"
        case .audioRunning: return "Audio isn't running"
        case .inputMonitoring: return "Allow Input Monitoring"
        case .microphone: return "Allow microphone access"
        }
    }

    public var detail: String {
        switch self {
        case .virtualDevice:
            return "The game hears iSoundboard through it."
        case .audioRunning:
            return "The mixer could not start. Check the device selection in Settings."
        case .inputMonitoring:
            return "Without it, hotkeys do nothing while a game is focused."
        case .microphone:
            return "Needed because your microphone is being mixed in. Mute it instead if you'd rather not grant access."
        }
    }
}

/// Whether the app is configured enough to be used.
public struct SetupStatus: Equatable, Sendable {
    public let unmet: [SetupRequirement]

    public var isReady: Bool { unmet.isEmpty }

    public init(unmet: [SetupRequirement]) {
        self.unmet = unmet
    }

    /// Ordered most fundamental first: there is no point chasing permissions
    /// while the audio route itself is wrong.
    public static func evaluate(hasVirtualDevice: Bool,
                                audioRunning: Bool,
                                hotkeysWorking: Bool,
                                microphoneGranted: Bool,
                                micMode: MicrophoneMode) -> SetupStatus {
        var unmet: [SetupRequirement] = []

        if !hasVirtualDevice { unmet.append(.virtualDevice) }
        if !audioRunning { unmet.append(.audioRunning) }
        if !hotkeysWorking { unmet.append(.inputMonitoring) }

        // Muting the microphone is a legitimate setup, not an incomplete one,
        // so access is only required when the mic is actually mixed in.
        if micMode != .muted && !microphoneGranted { unmet.append(.microphone) }

        return SetupStatus(unmet: unmet)
    }
}
