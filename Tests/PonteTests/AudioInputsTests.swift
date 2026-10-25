import XCTest
@testable import Ponte

/// Choosing a microphone, and what happens when the chosen one is not there.
///
/// The rule that matters: a pin that is not connected must never look like a pin that is working. The resolver is
/// pure so that rule has a test instead of a hope — the window and the recorder both read its answer, so they cannot
/// disagree about what is live.
final class AudioInputsTests: XCTestCase {

    private let builtIn = AudioInput(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let airpods = AudioInput(uid: "ponti.pods", name: "ponti.pods")
    private var all: [AudioInput] { [builtIn, airpods] }

    func testAPinnedDeviceThatIsConnectedIsUsed() {
        let r = AudioInputs.resolve(pinned: airpods.uid, available: all, defaultUID: builtIn.uid)
        XCTAssertEqual(r.input?.uid, airpods.uid)
        XCTAssertFalse(r.fellBack, "a pin that works is not a fallback")
    }

    func testAPinnedDeviceThatIsGoneFallsBackAndSaysSo() {
        let r = AudioInputs.resolve(pinned: "unplugged-headset", available: all, defaultUID: builtIn.uid)
        XCTAssertEqual(r.input?.uid, builtIn.uid, "the system default is the fallback")
        XCTAssertTrue(r.fellBack, "and the window is told, because a vanished pin must not look like a working one")
    }

    func testNoPinMeansTheSystemDefaultWithoutCallingItAFallback() {
        let r = AudioInputs.resolve(pinned: nil, available: all, defaultUID: airpods.uid)
        XCTAssertEqual(r.input?.uid, airpods.uid)
        XCTAssertFalse(r.fellBack, "choosing the default is not a fallback")
    }

    func testAMissingDefaultStillResolvesToSomething() {
        let r = AudioInputs.resolve(pinned: nil, available: all, defaultUID: "no-such-device")
        XCTAssertEqual(r.input?.uid, builtIn.uid, "the first input beats recording from nothing")
        XCTAssertFalse(r.fellBack)
    }

    func testNoDevicesAtAllIsNilRatherThanACrash() {
        let pinnedButEmpty = AudioInputs.resolve(pinned: "x", available: [], defaultUID: nil)
        XCTAssertNil(pinnedButEmpty.input)
        XCTAssertTrue(pinnedButEmpty.fellBack)
        XCTAssertNil(AudioInputs.resolve(pinned: nil, available: [], defaultUID: nil).input)
    }

    func testAPinWinsOverTheSystemDefaultEvenWhenTheDefaultIsSomethingElse() {
        // The whole point of pinning: plugging in AirPods must not silently take over an interview recording.
        let r = AudioInputs.resolve(pinned: builtIn.uid, available: all, defaultUID: airpods.uid)
        XCTAssertEqual(r.input?.uid, builtIn.uid)
        XCTAssertFalse(r.fellBack)
    }
}
