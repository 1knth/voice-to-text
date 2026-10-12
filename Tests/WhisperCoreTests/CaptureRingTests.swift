import XCTest
import WhisperCapture

final class CaptureRingTests: XCTestCase {
    func testBoundedSlotsAndReuse() throws {
        let ring = try XCTUnwrap(whisper_capture_create(4))
        defer { whisper_capture_destroy(ring) }
        XCTAssertEqual(whisper_capture_begin_read(ring), -1)
        for slot in 0..<4 {
            XCTAssertEqual(whisper_capture_begin_write(ring), Int32(slot))
            whisper_capture_commit_write(ring)
        }
        XCTAssertEqual(whisper_capture_begin_write(ring), -1)
        // A slot remains unavailable until the reader finishes converting it.
        XCTAssertEqual(whisper_capture_begin_read(ring), 0)
        XCTAssertEqual(whisper_capture_begin_write(ring), -1)
        whisper_capture_commit_read(ring)
        XCTAssertEqual(whisper_capture_begin_write(ring), 0)
        whisper_capture_commit_write(ring)
        for slot in [1, 2, 3, 0] {
            XCTAssertEqual(whisper_capture_begin_read(ring), Int32(slot))
            whisper_capture_commit_read(ring)
        }
        XCTAssertEqual(whisper_capture_begin_read(ring), -1)
    }
    func testInvalidCapacity() {
        XCTAssertNil(whisper_capture_create(0))
        XCTAssertNil(whisper_capture_create(3))
    }
    func testConcurrentOrderedHandoff() throws {
        let ring = try XCTUnwrap(whisper_capture_create(32))
        let slots = UnsafeMutablePointer<Int>.allocate(capacity: 32)
        slots.initialize(repeating: -1, count: 32)
        let counters = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counters.initialize(repeating: 0, count: 2)
        defer {
            whisper_capture_destroy(ring)
            slots.deinitialize(count: 32); slots.deallocate()
            counters.deinitialize(count: 2); counters.deallocate()
        }
        let group = DispatchGroup(), deadline = Date().addingTimeInterval(10)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for value in 0..<20_000 {
                var slot = whisper_capture_begin_write(ring)
                while slot < 0 {
                    if Date() > deadline { return }
                    Thread.sleep(forTimeInterval: 0.00001)
                    slot = whisper_capture_begin_write(ring)
                }
                slots[Int(slot)] = value
                whisper_capture_commit_write(ring)
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for expected in 0..<20_000 {
                var slot = whisper_capture_begin_read(ring)
                while slot < 0 {
                    if Date() > deadline { return }
                    Thread.sleep(forTimeInterval: 0.00001)
                    slot = whisper_capture_begin_read(ring)
                }
                if slots[Int(slot)] != expected { counters[1] += 1 }
                whisper_capture_commit_read(ring)
                counters[0] += 1
            }
        }
        // Wait for both workers before destroying any shared storage, even on failure.
        group.wait()
        XCTAssertEqual(counters[0], 20_000)
        XCTAssertEqual(counters[1], 0)
        XCTAssertEqual(whisper_capture_begin_read(ring), -1)
    }
}
