import Foundation
import AVFoundation
import WhisperCore

/// Explicit synthetic-audio test. Does not record a microphone or alter clipboard/focus.
enum InferenceSmokeTest {
    static func run() {
        var files: JobFiles?
        var directory: URL?
        let transcriber = Transcriber()
        var stage = "approval validation"
        do {
            guard let manifest = Bundle.main.url(forResource: "ApprovedInference", withExtension: "json") else {
                throw AppFailure("Approval manifest missing.")
            }
            let approval = try InferenceApproval.load(from: manifest)
            var config = Configuration(); config.cliPath = approval.cliPath; config.modelPath = approval.modelPath
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-test-\(UUID().uuidString)")
            let store = try JobFiles(root: root); files = store
            let dir = try store.create(); directory = dir
            let source = dir.appendingPathComponent("synthetic.aiff")
            stage = "speech fixture generation"
            let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", source.path, "-r", "150", "The quick brown fox jumps over the lazy dog."]
            say.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
            say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
            try say.run(); say.waitUntilExit()
            guard say.terminationStatus == 0 else { throw AppFailure("Apple speech fixture generation failed.") }
            let wav = dir.appendingPathComponent("recording.wav")
            stage = "native audio conversion"
            try convert(source: source, destination: wav)
            var result: Result<String?, Error>?
            let started = Date()
            stage = "Whisper inference"
            try transcriber.start(audio: wav, directory: dir, config: config) { result = $0 }
            let until = Date().addingTimeInterval(config.transcriptionTimeout + 5)
            while result == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let result else {
                transcriber.cancel()
                while transcriber.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                throw AppFailure("Smoke-test deadline exceeded.")
            }
            guard let text = try result.get(), text.lowercased().contains("quick brown fox") else {
                throw AppFailure("Synthetic phrase was not recognized as expected.")
            }
            print("Local inference smoke test passed in \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds.")
            print("Synthetic transcript: \(text)")
            try store.remove(dir); directory = nil
            try FileManager.default.removeItem(at: root); files = nil
        } catch {
            if let files, let directory { try? files.remove(directory) }
            if let files { try? FileManager.default.removeItem(at: files.root) }
            fputs("Inference smoke test failed during \(stage): \(String(reflecting: error))\n", stderr)
            exit(1)
        }
    }

    private static func convert(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let from = input.processingFormat
        guard let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 8192) else {
            throw AppFailure("Synthetic audio conversion setup failed.")
        }
        let writer = try AVAudioFile(forWriting: destination, settings: to.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var finished = false
        while !finished {
            let remaining = input.length - input.framePosition
            if remaining > 0 {
                try input.read(into: readBuffer, frameCount: AVAudioFrameCount(min(4096, remaining)))
            } else { readBuffer.frameLength = 0 }
            let eof = readBuffer.frameLength == 0
            var supplied = false
            var status: AVAudioConverterOutputStatus = .haveData
            while status == .haveData {
                var error: NSError?
                status = converter.convert(to: output, error: &error) { _, state in
                    if eof { state.pointee = .endOfStream; return nil }
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return readBuffer
                }
                if let error { throw error }
                if status == .error { throw AppFailure("Synthetic audio conversion failed.") }
                if output.frameLength > 0 { try writer.write(from: output) }
            }
            finished = eof
        }
    }
}
