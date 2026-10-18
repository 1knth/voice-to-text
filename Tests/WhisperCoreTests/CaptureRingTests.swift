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
    func testLatestLevelMailboxOverwritesWithoutQueueing() {
        XCTAssertNotEqual(whisper_level_is_lock_free(), 0)
        for value in 0..<100_000 {
            whisper_level_store(Float(value) / 100_000)
        }
        XCTAssertEqual(whisper_level_load(), 0.99999, accuracy: 0.000001)
    }
    func testLevelResponseAttackReleaseAndDeltaConsistency() {
        func response(_ intervals: [Double], initial: Double = 0, target: Double) -> Double {
            intervals.reduce(initial) { whisper_level_step($0, target, $1) }
        }

        let attack = response(Array(repeating: 1.0 / 60, count: 6), target: 1)
        let release = response(Array(repeating: 1.0 / 60, count: 6), initial: 1, target: 0)
        XCTAssertEqual(attack, 0.838, accuracy: 0.002) // 100 ms: 84% of target
        XCTAssertEqual(release, 0.490, accuracy: 0.002) // 100 ms: 49% remains

        let regular = response(Array(repeating: 1.0 / 60, count: 60), target: 1)
        let irregular = response([0.007, 0.031, 0.012, 0.05, 0.019, 0.05, 0.043] + Array(repeating: 0.05, count: 15) + [0.038], target: 1)
        XCTAssertEqual(regular, 1 - exp(-1.0 / 0.055), accuracy: 0.000001)
        XCTAssertEqual(irregular, 1 - exp(-1.0 / 0.055), accuracy: 0.000001)
        XCTAssertEqual(whisper_level_step(0, 1, 1), whisper_level_step(0, 1, 0.05), accuracy: 0.000001)
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
