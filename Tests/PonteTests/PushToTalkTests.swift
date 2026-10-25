import XCTest
@testable import Ponte

/// What the dictation key does in each mode, in each state.
///
/// The cases that matter are the ones nobody can reproduce on demand: a tap shorter than the engine's floor, a release
/// arriving while the take is still starting, a press during a transcription. They are arithmetic here so the app does
/// not have to discover them live.
final class PushToTalkTests: XCTestCase {

    // MARK: toggle — unchanged behaviour

    func testToggleStartsFromIdleAndFinishesWhileRecording() {
        XCTAssertEqual(PushToTalk.action(mode: .toggle, state: .idle, event: .press), .start)
        XCTAssertEqual(PushToTalk.action(mode: .toggle, state: .recording, event: .press), .finish)
    }

    func testToggleIgnoresAReleaseEntirely() {
        // The key-up of the chord that started a dictation must never end it.
        for state in [AppState.idle, .starting, .recording, .working] {
            XCTAssertEqual(PushToTalk.action(mode: .toggle, state: state, event: .release), .none,
                           "release in \(state)")
        }
    }

    func testToggleDoesNothingMidStartOrMidTranscription() {
        XCTAssertEqual(PushToTalk.action(mode: .toggle, state: .starting, event: .press), .none)
        XCTAssertEqual(PushToTalk.action(mode: .toggle, state: .working, event: .press), .none)
    }

    // MARK: push-to-talk

    func testHoldStartsAndReleaseFinishes() {
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .idle, event: .press), .start)
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .recording, event: .release), .finish)
    }

    func testATapShorterThanTheEngineFloorCancelsRatherThanLeavingItRunning() {
        // A release that lands while the take is still starting must not strand a recording: nothing was captured, so
        // there is nothing to transcribe and nothing to keep.
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .starting, event: .release), .cancel)
    }

    func testASecondPressWhileHoldingIsIgnored() {
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .recording, event: .press), .none)
    }

    func testAReleaseWhileTranscribingIsIgnored() {
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .working, event: .release), .none)
    }

    func testAReleaseWithNothingHeldIsIgnored() {
        XCTAssertEqual(PushToTalk.action(mode: .pushToTalk, state: .idle, event: .release), .none)
    }

    // MARK: the ceiling

    func testTheCeilingEndsATakeRatherThanLettingItRun() {
        XCTAssertFalse(PushToTalk.hasReachedCeiling(PushToTalk.ceiling - 1))
        XCTAssertTrue(PushToTalk.hasReachedCeiling(PushToTalk.ceiling))
        XCTAssertTrue(PushToTalk.hasReachedCeiling(PushToTalk.ceiling + 60))
    }

    func testTheCeilingIsMinutesNotSeconds() {
        // It exists for a lost key-up, not as a length limit: a five-minute dictation has to be possible.
        XCTAssertGreaterThanOrEqual(PushToTalk.ceiling, 120)
        XCTAssertLessThanOrEqual(PushToTalk.ceiling, 1_200)
    }

    // MARK: the setting

    func testAnUnknownStoredModeFallsBackToToggle() {
        UserDefaults.standard.set("nonsense", forKey: SettingKey.hotKeyMode)
        XCTAssertEqual(HotKeyMode.current, .toggle)
        UserDefaults.standard.removeObject(forKey: SettingKey.hotKeyMode)
    }

    func testTheModeRoundTripsThroughDefaults() {
        Settings.hotKeyModeSetting = .pushToTalk
        XCTAssertEqual(HotKeyMode.current, .pushToTalk)
        Settings.hotKeyModeSetting = .toggle
        XCTAssertEqual(HotKeyMode.current, .toggle)
    }
}
