import XCTest
@testable import WhisperCore

final class JobFilesTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testPrivatePermissionsAndCleanup() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let files = try JobFiles(root: parent.appendingPathComponent("jobs"))
        let job = try files.create()
        let attrs = try FileManager.default.attributesOfItem(atPath: job.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try files.remove(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
    }
    func testRefusesSymlinkRootAndOutsideDeletion() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let external = parent.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertThrowsError(try JobFiles(root: link))
        let files = try JobFiles(root: parent.appendingPathComponent("jobs"))
        XCTAssertThrowsError(try files.remove(external))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
    func testStartupCleanupRemovesFreshJobsButKeepsUnrecognizedEntries() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let files = try JobFiles(root: parent.appendingPathComponent("jobs"))
        let fresh = try files.create()
        try Data(repeating: 0, count: 1024).write(to: fresh.appendingPathComponent("recording.wav"))
        try "temporary transcript".write(to: fresh.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let unmarked = files.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        let sentinel = parent.appendingPathComponent("sentinel")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fresh.appendingPathComponent("nested-link"), withDestinationURL: sentinel)
        let externalJob = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: externalJob, withIntermediateDirectories: false)
        let rootLink = files.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: externalJob)
        try files.removeRecognizedJobs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalJob.path))
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rootLink.path), externalJob.path)
        XCTAssertNoThrow(try files.removeRecognizedJobs())
    }
    func testStaleCleanupKeepsUnrelatedFilesAndNestedLinkDestination() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let files = try JobFiles(root: parent.appendingPathComponent("jobs"))
        let job = try files.create()
        let sentinel = parent.appendingPathComponent("sentinel")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: job.appendingPathComponent("link"), withDestinationURL: sentinel)
        let unrelated = files.root.appendingPathComponent("unrelated")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        try files.removeStale(olderThan: Date().addingTimeInterval(60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.path))
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
    }
}
