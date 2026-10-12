import XCTest
@testable import WhisperCore

final class InferenceApprovalTests: XCTestCase {
    private func fixture() throws -> (URL, InferenceApproval) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let cli = root.appendingPathComponent("cli"), model = root.appendingPathComponent("model")
        try Data("executable fixture, never executed".utf8).write(to: cli)
        try Data("model fixture, never parsed".utf8).write(to: model)
        let approval = InferenceApproval(approvedForLocalTesting: true, cliPath: cli.path, modelPath: model.path,
            artifacts: [.init(path: cli.path, sha256: try InferenceApproval.digest(cli)),
                        .init(path: model.path, sha256: try InferenceApproval.digest(model))])
        return (root, approval)
    }
    func testApprovedHashesAndChangedArtifact() throws {
        let (root, approval) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try approval.validate(cli: approval.cliPath, model: approval.modelPath, workingDirectory: root))
        try Data("changed".utf8).write(to: URL(fileURLWithPath: approval.cliPath))
        XCTAssertThrowsError(try approval.validate(cli: approval.cliPath, model: approval.modelPath, workingDirectory: root))
    }
    func testUnknownBackendBlocked() throws {
        let (root, approval) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("libggml-cpu-unapproved.so"))
        XCTAssertThrowsError(try approval.validate(cli: approval.cliPath, model: approval.modelPath, workingDirectory: root))
    }
    func testUnapprovedModelPathBlocked() throws {
        let (root, approval) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other-model")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: approval.modelPath), to: other)
        XCTAssertThrowsError(try approval.validate(cli: approval.cliPath, model: other.path, workingDirectory: root))
    }
    func testMissingConsentBlocked() throws {
        let (root, approval) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let denied = InferenceApproval(approvedForLocalTesting: false, cliPath: approval.cliPath,
                                      modelPath: approval.modelPath, artifacts: approval.artifacts)
        XCTAssertThrowsError(try denied.validate(cli: denied.cliPath, model: denied.modelPath, workingDirectory: root))
    }
    func testShortAudioAndFormatBoundaries() {
        XCTAssertFalse(InferenceAudioPolicy.accepts(sampleRate: 16000, channels: 1, frames: 7999))
        XCTAssertTrue(InferenceAudioPolicy.accepts(sampleRate: 16000, channels: 1, frames: 8000))
        XCTAssertTrue(InferenceAudioPolicy.accepts(sampleRate: 16000, channels: 1, frames: 960000))
        XCTAssertFalse(InferenceAudioPolicy.accepts(sampleRate: 16000, channels: 1, frames: 960001))
        XCTAssertFalse(InferenceAudioPolicy.accepts(sampleRate: 48000, channels: 1, frames: 8000))
        XCTAssertFalse(InferenceAudioPolicy.accepts(sampleRate: 16000, channels: 2, frames: 8000))
    }
}
