import Testing
@testable import SoundboardCore

@Suite("PushToTalkCoordinator")
struct PushToTalkCoordinatorTests {

    @Test("holds the key down when a clip starts")
    func opensMicOnFirstSound() {
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        #expect(ptt.micShouldBeOpen == false)
        ptt.soundStarted("play-1", at: 0)
        #expect(ptt.micShouldBeOpen == true)
    }

    @Test("releases the key once the tail has elapsed")
    func closesAfterTailDelay() {
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        ptt.soundStarted("play-1", at: 0)
        ptt.soundFinished("play-1", at: 1.0)
        ptt.tick(at: 1.3)
        #expect(ptt.micShouldBeOpen == false)
    }

    @Test("stays held during the release tail")
    func staysOpenDuringTail() {
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        ptt.soundStarted("play-1", at: 0)
        ptt.soundFinished("play-1", at: 1.0)
        ptt.tick(at: 1.1)
        #expect(ptt.micShouldBeOpen == true)
    }

    @Test("a clip fired during the tail cancels the pending release")
    func retriggerDuringTailCancelsClose() {
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        ptt.soundStarted("play-1", at: 0)
        ptt.soundFinished("play-1", at: 1.0)
        ptt.soundStarted("play-2", at: 1.1)
        ptt.tick(at: 1.3)
        #expect(ptt.micShouldBeOpen == true)
    }

    @Test("interrupting a clip keeps the key held for its replacement")
    func interruptKeepsMicOpen() {
        // One clip at a time: a new sound cancels the old. The cancelled clip's
        // completion can still arrive afterwards and must not release the key
        // out from under the clip that replaced it.
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        ptt.soundStarted("play-1", at: 0)
        ptt.soundFinished("play-1", at: 1.0)
        ptt.soundStarted("play-2", at: 1.0)

        ptt.soundFinished("play-1", at: 1.05)   // late completion
        ptt.tick(at: 1.4)
        #expect(ptt.micShouldBeOpen == true)
    }

    @Test("the key still releases once the replacing clip ends")
    func closesAfterReplacementEnds() {
        var ptt = PushToTalkCoordinator(tailDelay: 0.25)
        ptt.soundStarted("play-1", at: 0)
        ptt.soundFinished("play-1", at: 1.0)
        ptt.soundStarted("play-2", at: 1.0)
        ptt.soundFinished("play-2", at: 2.0)
        ptt.tick(at: 2.3)
        #expect(ptt.micShouldBeOpen == false)
    }
}
