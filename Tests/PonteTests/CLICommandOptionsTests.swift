import XCTest
@testable import Ponte

final class CLICommandOptionsTests: XCTestCase {
    func testRejectsOptionsFromAnotherCommand() {
        XCTAssertEqual(CLICommandOptions.error(command: "--devices", arguments: ["--language", "fr"]),
                       "error: --language is not valid with --devices")
    }

    func testAllowsRecordingOptions() {
        XCTAssertNil(CLICommandOptions.error(command: "--record",
                                             arguments: ["--live", "--out", "take.wav", "--mic", "Built-in"]))
    }

    func testAllowsHUDRenderingOptions() {
        XCTAssertNil(CLICommandOptions.error(command: "--hud-render",
                                             arguments: ["--turning", "--words", "hello", "--rate", "1.2"]))
    }

    func testPositionalOnlyCommandsNeedNoOptionRule() {
        XCTAssertNil(CLICommandOptions.error(command: "--download", arguments: ["all"]))
    }
}
