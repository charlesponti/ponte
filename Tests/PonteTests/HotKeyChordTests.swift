import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Ponte

/// The rules that decide whether a chord can be a global hotkey, and how it reads.
///
/// These matter more than they look: a chord the recorder accepts but Carbon refuses leaves someone with a hotkey
/// that silently does nothing, and a chord that is *too* permissive — a bare letter — takes that key away from
/// every application on the machine.
final class HotKeyChordTests: XCTestCase {

    func testDefaultIsTheChordPonteShipsWith() {
        XCTAssertEqual(HotKeyChord.default.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotKeyChord.default.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(HotKeyChord.default.display, "⌥⌘Space")
        XCTAssertTrue(HotKeyChord.default.isUsable)
    }

    func testABareLetterIsRefused() {
        // kVK_ANSI_A with no modifiers: usable by the recorder, unusable as a hotkey.
        let chord = HotKeyChord(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        XCTAssertFalse(chord.isUsable)
        XCTAssertNotNil(chord.rejection)
    }

    func testShiftAloneIsNotEnoughBecauseShiftAIsHowYouTypeA() {
        let chord = HotKeyChord(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        XCTAssertFalse(chord.isUsable, "⇧A is a capital A, not a shortcut")
    }

    func testAnyStrongModifierMakesAChordUsable() {
        for mod in [UInt32(cmdKey), UInt32(optionKey), UInt32(controlKey)] {
            let chord = HotKeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: mod)
            XCTAssertTrue(chord.isUsable, "modifier \(mod) should be enough")
        }
    }

    func testAFunctionKeyNeedsNoModifier() {
        for key in [kVK_F13, kVK_F19] {
            let chord = HotKeyChord(keyCode: UInt32(key), modifiers: 0)
            XCTAssertTrue(chord.isUsable, "F-keys type nothing, so a bare one is safe")
        }
    }

    func testDisplayOrdersModifiersTheWayMacOSDoes() {
        let all = HotKeyChord(keyCode: UInt32(kVK_ANSI_V),
                              modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(all.display, "⌃⌥⇧⌘V")
    }

    func testModifiersComeFromTheEventTheWayCarbonWantsThem() {
        let flags: NSEvent.ModifierFlags = [.option, .command]
        XCTAssertEqual(HotKeyChord.carbonModifiers(from: flags), UInt32(optionKey | cmdKey))
        XCTAssertEqual(HotKeyChord.carbonModifiers(from: []), 0)
        XCTAssertEqual(HotKeyChord.carbonModifiers(from: [.control, .shift]),
                       UInt32(controlKey | shiftKey))
    }

    func testAFreshInstallReadsTheShippedDefaults() {
        // The window reads through UserDefaults, and a machine that has never run Ponte has no values stored at all.
        // Registering the defaults is what makes the first launch behave like the intended one.
        Settings.registerDefaults()
        XCTAssertTrue(Settings.autoPaste, "auto-paste is on out of the box")
        XCTAssertFalse(Settings.keepAudio, "audio is deleted once transcribed unless asked otherwise")
        XCTAssertEqual(Settings.parakeetModel, .ultra)
        XCTAssertEqual(Settings.language, "en")
    }

    func testChordsCompareByShapeSoARecordedDuplicateIsRecognised() {
        XCTAssertEqual(HotKeyChord(keyCode: 49, modifiers: 2304),
                       HotKeyChord(keyCode: 49, modifiers: 2304))
        XCTAssertNotEqual(HotKeyChord(keyCode: 49, modifiers: 2304),
                          HotKeyChord(keyCode: 49, modifiers: 2304 | UInt32(shiftKey)))
    }
}
