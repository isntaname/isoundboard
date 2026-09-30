import Foundation

/// What your real microphone does while the soundboard is live.
public enum MicrophoneMode: String, CaseIterable, Sendable, Codable {
    /// Never pass the microphone through — only clips reach the game.
    case muted
    /// Talk normally; clips are mixed on top of your voice.
    case always
    /// Talk normally, but drop the microphone while a clip is playing so the
    /// clip goes out clean, without room noise underneath it.
    case whenIdle

    public var label: String {
        switch self {
        case .muted: return "Mute my real mic"
        case .always: return "Mix my mic in always"
        case .whenIdle: return "Mix my mic in, except while a clip plays"
        }
    }

    public var detail: String {
        switch self {
        case .muted: return "Teammates hear only your soundboard."
        case .always: return "Teammates hear you and your clips together."
        case .whenIdle: return "Your voice cuts out for the length of each clip."
        }
    }

    public func micGain(isClipPlaying: Bool) -> Float {
        switch self {
        case .muted: return 0
        case .always: return 1
        case .whenIdle: return isClipPlaying ? 0 : 1
        }
    }
}
