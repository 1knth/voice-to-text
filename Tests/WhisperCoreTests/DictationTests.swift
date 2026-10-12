import XCTest
@testable import WhisperCore

final class DictationTests: XCTestCase {
    func testSingleJobAndValidTransitions() {
        var gate = JobGate()
        let job = gate.begin()!
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.advance(job, to: .delivering))
        for phase in [Phase.recording, .stopping, .transcribing, .delivering] {
            XCTAssertTrue(gate.advance(job, to: phase))
        }
        gate.finish(); XCTAssertEqual(gate.phase, .idle)
    }
    func testCancellationRejectsStaleResults() {
        var gate = JobGate(); let old = gate.begin()!
        gate.finish(); let new = gate.begin()!
        XCTAssertFalse(gate.advance(old, to: .recording))
        XCTAssertFalse(gate.owns(old)); XCTAssertTrue(gate.owns(new))
    }
    func testQuickReleaseCanStopStartup() {
        var gate = JobGate(); let job = gate.begin()!
        XCTAssertTrue(gate.advance(job, to: .stopping))
        XCTAssertFalse(gate.advance(job, to: .recording))
    }
    func testConfigurationBounds() {
        var config = Configuration()
        config.recordingLimit = .infinity; config.transcriptionTimeout = -2
        config.modifiers = 0; config.keyCode = 53; config.validate()
        XCTAssertEqual(config.recordingLimit, 60)
        XCTAssertEqual(config.transcriptionTimeout, 10)
        XCTAssertEqual(config.keyCode, Shortcut.defaultKey)
        XCTAssertEqual(config.modifiers, Shortcut.defaultModifiers)
    }
    func testOptionDDefaultAndShortcutValidation() {
        let config = Configuration()
        XCTAssertEqual(config.keyCode, 2)
        XCTAssertEqual(config.modifiers, 0x80000)
        XCTAssertTrue(Shortcut.isValid(key: 2, modifiers: 0x80000))
        XCTAssertTrue(Shortcut.isValid(key: 5, modifiers: 0x100000))
        XCTAssertFalse(Shortcut.isValid(key: 2, modifiers: 0))
        XCTAssertFalse(Shortcut.isValid(key: 58, modifiers: 0x80000))
        XCTAssertFalse(Shortcut.isValid(key: 53, modifiers: 0x100000))
        XCTAssertFalse(Shortcut.isValid(key: 200, modifiers: 0x80000))
    }
    func testShortcutConfigurationRoundTrip() throws {
        var config = Configuration(); config.keyCode = 5; config.modifiers = 0x120000
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.keyCode, 5)
        XCTAssertEqual(restored.modifiers, 0x120000)
    }
    func testTranscriptNormalization() {
        XCTAssertEqual(Transcript.normalize(" hello\n world\t "), "hello world")
        XCTAssertNil(Transcript.normalize(" [BLANK_AUDIO] "))
        XCTAssertNil(Transcript.normalize(" \n "))
    }
    func testStrictTerminalAndKnownChanges() {
        XCTAssertFalse(DeliveryPolicy.mayPaste(automatic: true, changed: false,
            sameTarget: true, editable: true, terminal: true, bestEffort: false))
        XCTAssertFalse(DeliveryPolicy.mayPaste(automatic: true, changed: true,
            sameTarget: true, editable: true, terminal: false, bestEffort: true))
        XCTAssertTrue(DeliveryPolicy.mayPaste(automatic: true, changed: false,
            sameTarget: true, editable: true, terminal: false, bestEffort: false))
        XCTAssertFalse(DeliveryPolicy.mayPaste(automatic: false, changed: false,
            sameTarget: true, editable: true, terminal: false, bestEffort: false))
    }
}
