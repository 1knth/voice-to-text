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
    func testRecorderLifecycleStopWaitsForQueuedSetupBeforeCleanup() {
        let lifecycle = SerialLifecycleQueue(label: "test.recorder.lifecycle")
        let setupEntered = expectation(description: "setup entered")
        let stopFinished = expectation(description: "stop finished")
        let allowSetup = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var events: [String] = []
        lifecycle.submit {
            setupEntered.fulfill()
            allowSetup.wait()
            lock.lock(); events.append("setup-finished"); lock.unlock()
        }
        wait(for: [setupEntered], timeout: 2)
        lifecycle.submit {
            lock.lock(); events.append("stop-cleanup"); lock.unlock()
            stopFinished.fulfill()
        }
        allowSetup.signal()
        wait(for: [stopFinished], timeout: 2)
        lock.lock(); let result = events; lock.unlock()
        XCTAssertEqual(result, ["setup-finished", "stop-cleanup"])
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
    func testRebindingReleasesDefaultShortcuts() {
        XCTAssertEqual(Shortcut.action(key: 0, modifiers: 0x80000,
                                       configuredKey: 0, configuredModifiers: 0x80000), .configured)
        for modifiers: UInt64 in [0x80000, 0xA0000] {
            XCTAssertNil(Shortcut.action(key: 2, modifiers: modifiers,
                                         configuredKey: 0, configuredModifiers: 0x80000))
        }
        XCTAssertNil(Shortcut.action(key: 0, modifiers: 0xA0000,
                                     configuredKey: 0, configuredModifiers: 0x80000))
        XCTAssertEqual(Shortcut.action(key: 2, modifiers: 0x80000,
                                       configuredKey: 2, configuredModifiers: 0x80000), .configured)
    }
    func testDeliverySettingIsIndependentOfShortcut() {
        for (key, modifiers): (UInt16, UInt64) in [(2, 0x80000), (2, 0xA0000), (5, 0x120000)] {
            for automatic in [true, false] {
                var config = Configuration()
                config.keyCode = key; config.modifiers = modifiers
                config.automaticPaste = automatic; config.validate()
                XCTAssertEqual(Shortcut.action(key: key, modifiers: modifiers,
                    configuredKey: config.keyCode, configuredModifiers: config.modifiers), .configured)
                XCTAssertEqual(DeliveryPolicy.mayPaste(automatic: config.automaticPaste, changed: true,
                    sameTarget: false, editable: false, terminal: false, bestEffort: false, global: true), automatic)
            }
        }
    }
    func testShortcutConfigurationRoundTrip() throws {
        var config = Configuration(); config.keyCode = 5; config.modifiers = 0x120000
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.keyCode, 5)
        XCTAssertEqual(restored.modifiers, 0x120000)
    }
    func testDirectTypingIsDefaultAndOlderConfigurationsStillLoad() throws {
        XCTAssertEqual(Configuration().deliveryMode, .type)
        let legacy = Data(#"{"automaticPaste":true,"keyCode":5,"modifiers":1179648}"#.utf8)
        let restored = try JSONDecoder().decode(Configuration.self, from: legacy)
        XCTAssertEqual(restored.keyCode, 5)
        XCTAssertEqual(restored.deliveryMode, .type)
        XCTAssertFalse(restored.preserveClipboard)
    }
    func testDeliveryModeMapsToSettings() {
        var config = Configuration()
        config.deliveryMode = .paste
        XCTAssertTrue(config.automaticPaste); XCTAssertFalse(config.directTyping)
        config.deliveryMode = .copy
        XCTAssertFalse(config.automaticPaste); XCTAssertEqual(config.deliveryMode, .copy)
        config.deliveryMode = .type
        XCTAssertTrue(config.automaticPaste); XCTAssertTrue(config.directTyping)
    }
    func testTypingChunksRespectLimitAndCharacters() {
        let text = String(repeating: "a", count: 19) + "👍🏽" + "bc"
        let chunks = DeliveryPolicy.typingChunks(text, limit: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(String(utf16CodeUnits: chunks[1], count: chunks[1].count), "👍🏽bc")
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), text)
        XCTAssertTrue(DeliveryPolicy.typingChunks("").isEmpty)
    }
    func testTranscriptNormalization() {
        XCTAssertEqual(Transcript.normalize(" hello\n world\t "), "hello world")
        XCTAssertNil(Transcript.normalize(" [BLANK_AUDIO] "))
        XCTAssertNil(Transcript.normalize(" \n "))
    }
    func testGlobalPasteDoesNotRequireAnAccessibleEditorOrOriginalFocus() {
        XCTAssertTrue(DeliveryPolicy.mayPaste(automatic: true, changed: true,
            sameTarget: false, editable: false, terminal: false, bestEffort: false, global: true))
        XCTAssertTrue(DeliveryPolicy.mayPaste(automatic: true, changed: false,
            sameTarget: false, editable: false, terminal: true, bestEffort: false, global: true))
        XCTAssertFalse(DeliveryPolicy.mayPaste(automatic: false, changed: false,
            sameTarget: true, editable: true, terminal: false, bestEffort: true, global: true))
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
