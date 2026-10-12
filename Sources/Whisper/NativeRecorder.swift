import AVFoundation
import Foundation
import WhisperCapture

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Preallocated bounded capture pool; conversion and disk writes happen on a worker.
final class NativeRecorder {
    private let engine = AVAudioEngine()
    private let worker = DispatchQueue(label: "Whisper.audio-writer", qos: .userInitiated)
    private var slots: [AVAudioPCMBuffer] = []
    private var ring: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var outputFormat: AVAudioFormat?
    private var tapInstalled = false
    private var reportedReady = false
    private var captureFault = false
    private var writerError: Error?
    private var configurationObserver: NSObjectProtocol?
    private var frameBudget = 0
    private var capturedFrames = 0
    private var reachedLimit = false
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onLimit: (() -> Void)?

    deinit { if let ring { whisper_capture_destroy(ring) } }

    func start(url: URL, durationLimit: TimeInterval) throws {
        let node = engine.inputNode
        try prepare(url: url, format: node.outputFormat(forBus: 0), durationLimit: durationLimit)
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { _ = stop(); throw error }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.onFailure?(AppFailure("Microphone configuration changed. Recording stopped; try again with the intended input."))
            }
    }

    private func prepare(url: URL, format: AVAudioFormat, durationLimit: TimeInterval) throws {
        guard ring == nil else { throw AppFailure("Recorder already used.") }
        guard format.sampleRate > 0, format.sampleRate <= 192000,
              format.channelCount > 0, format.channelCount <= 8,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw AppFailure("Unsupported microphone format. Try the system default microphone.")
        }
        self.converter = converter; outputFormat = output
        file = try AVAudioFile(forWriting: url, settings: output.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        slots = try (0..<32).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw AppFailure("Could not allocate capture buffers.")
            }
            return buffer
        }
        guard let ring = whisper_capture_create(32) else {
            throw AppFailure("Could not allocate a lock-free audio queue.")
        }
        self.ring = ring
        reportedReady = false; captureFault = false; writerError = nil
        frameBudget = Int(format.sampleRate * durationLimit)
        capturedFrames = 0; reachedLimit = false
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume(); self.timer = timer
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard !captureFault, !reachedLimit, let ring, buffer.frameLength > 0 else { return }
        guard let src = buffer.floatChannelData, !buffer.format.isInterleaved,
              buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == slots[0].format.channelCount,
              buffer.format.sampleRate == slots[0].format.sampleRate else {
            captureFailure("Microphone audio format changed during recording."); return
        }
        // AVAudioEngine's requested tap size is a hint, not a maximum. Split
        // larger hardware callbacks across fixed preallocated slots without loss.
        let frames = min(Int(buffer.frameLength), max(0, frameBudget - capturedFrames))
        var offset = 0
        while offset < frames {
            let index = whisper_capture_begin_write(ring)
            guard index >= 0 else {
                captureFailure("Audio writer fell behind: the capture queue is full."); return
            }
            let slot = slots[Int(index)]
            guard let dst = slot.floatChannelData else {
                captureFailure("Audio capture buffer unavailable."); return
            }
            let count = min(Int(slot.frameCapacity), frames - offset)
            slot.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dst[channel], src[channel].advanced(by: offset), count * MemoryLayout<Float>.size)
            }
            whisper_capture_commit_write(ring)
            capturedFrames += count; offset += count
        }
        if !reportedReady {
            reportedReady = true
            DispatchQueue.main.async { [weak self] in self?.onReady?() }
        }
        if capturedFrames >= frameBudget {
            reachedLimit = true
            DispatchQueue.main.async { [weak self] in self?.onLimit?() }
        }
    }

    private func captureFailure(_ message: String) {
        captureFault = true
        DispatchQueue.main.async { [weak self] in self?.onFailure?(AppFailure(message)) }
    }

    private func drain() {
        guard let ring else { return }
        while true {
            let index = whisper_capture_begin_read(ring)
            guard index >= 0 else { return }
            if writerError == nil {
                do { try convert(slots[Int(index)]) }
                catch {
                    writerError = error
                    DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
                }
            }
            whisper_capture_commit_read(ring)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws {
        guard let converter, let outputFormat, let file else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AppFailure("Audio conversion allocation failed.")
        }
        var supplied = false
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            if output.frameLength > 0 { try file.write(from: output) }
            if status == .error { throw AppFailure("Microphone conversion failed.") }
            if status != .haveData { break }
        }
    }

    /// Synthetic regression test using the real capture/queue/converter/writer path,
    /// without opening an input node, recording a microphone, or invoking inference.
    static func verifyCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-capture-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for (rate, channels, limit) in [(48000.0, AVAudioChannelCount(1), 60.0),
                                       (96000.0, AVAudioChannelCount(2), 60.0),
                                       (44100.0, AVAudioChannelCount(1), 60.0),
                                       (48000.0, AVAudioChannelCount(1), 0.5)] {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: channels, interleaved: false),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000),
                  let data = input.floatChannelData else { throw AppFailure("Capture test setup failed.") }
            let url = root.appendingPathComponent("fixture.wav")
            let recorder = NativeRecorder()
            try recorder.prepare(url: url, format: format, durationLimit: limit)
            var sourceFrames = 0
            for block in 0..<120 {
                let count = [4800, 8192, 12000, 1024][block % 4]
                input.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(channels) {
                    for frame in 0..<count {
                        data[channel][frame] = Float(0.15 * sin(2 * .pi * 440 * Double(sourceFrames + frame) / rate))
                    }
                }
                recorder.capture(input)
                sourceFrames += count
                // Keep synthetic production paced to the real writer; wall-clock
                // input is intentionally accelerated rather than a microphone test.
                recorder.worker.sync { recorder.drain() }
                if recorder.captureFault {
                    _ = recorder.stop(); throw AppFailure("Synthetic capture unexpectedly stopped.")
                }
            }
            if let error = recorder.stop() { throw error }
            let file = try AVAudioFile(forReading: url)
            let captured = min(sourceFrames, Int(rate * limit))
            let expected = Int64((Double(captured) * 16000 / rate).rounded())
            guard abs(file.length - expected) <= 1, file.processingFormat.channelCount == 1,
                  file.processingFormat.sampleRate == 16000 else {
                throw AppFailure("Capture test lost frames: expected \(expected), wrote \(file.length).")
            }
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw AppFailure("Capture test output unavailable.")
            }
            try file.read(into: output, frameCount: AVAudioFrameCount(file.length))
            guard let samples = output.floatChannelData, output.frameLength > 0 else {
                throw AppFailure("Capture test output is empty.")
            }
            // Verify waveform continuity across hardware callback/slot boundaries,
            // allowing resampler start/end transients. Missing slices break this.
            var squareError = 0.0
            let start = 128, end = Int(output.frameLength) - 128
            for frame in start..<end {
                let expectedSample = 0.15 * sin(2 * .pi * 440 * Double(frame) / 16000)
                let delta = Double(samples[0][frame]) - expectedSample
                squareError += delta * delta
            }
            guard sqrt(squareError / Double(end - start)) < 0.02 else {
                throw AppFailure("Capture test waveform discontinuity.")
            }
            print("Capture passed: \(Int(rate)) Hz, \(channels) channel(s), \(String(format: "%.2f", Double(file.length) / 16000)) seconds, 4,800–12,000-frame callbacks.")
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Caller must stop capture before deleting audio. Worker completion closes the file.
    @discardableResult func stop() -> Error? {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop(); timer?.cancel(); timer = nil
        worker.sync {
            drain()
            if let converter, let format = outputFormat, let file, writerError == nil,
               let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
                var error: NSError?
                var status: AVAudioConverterOutputStatus = .haveData
                while status == .haveData {
                    status = converter.convert(to: output, error: &error) { _, state in
                        state.pointee = .endOfStream; return nil
                    }
                    if let error { writerError = error; break }
                    do { if output.frameLength > 0 { try file.write(from: output) } }
                    catch { writerError = error; break }
                }
            }
            file = nil; converter = nil
        }
        return writerError
    }
}
