import Foundation

/// Decides when the game's microphone needs to be held open.
///
/// Time is passed in rather than read from a clock, so behaviour is
/// deterministic and testable without waiting.
public struct PushToTalkCoordinator {

    public private(set) var micShouldBeOpen = false

    /// Playbacks currently sounding. The key is held while any remain.
    private var playing: Set<String> = []

    /// When the key may be released, once nothing is playing.
    private var closeMicAt: TimeInterval?

    private let tailDelay: TimeInterval

    public init(tailDelay: TimeInterval) {
        self.tailDelay = tailDelay
    }

    public mutating func soundStarted(_ id: String, at now: TimeInterval) {
        playing.insert(id)
        // Cancel any pending release, or a stale deadline from the previous
        // clip will drop the key partway through this one.
        closeMicAt = nil
        micShouldBeOpen = true
    }

    public mutating func soundFinished(_ id: String, at now: TimeInterval) {
        playing.remove(id)
        if playing.isEmpty { closeMicAt = now + tailDelay }
    }

    /// Call periodically. Releases the key once the tail has elapsed.
    public mutating func tick(at now: TimeInterval) {
        guard let deadline = closeMicAt, now >= deadline else { return }
        micShouldBeOpen = false
        closeMicAt = nil
    }
}
