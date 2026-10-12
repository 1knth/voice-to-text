import Foundation
import AVFoundation
import Darwin
import WhisperCore

final class Transcriber {
    private var process: Process?
    private var deadline: DispatchWorkItem?
    private var cancelled = false
    private var timedOut = false

    func start(audio: URL, directory: URL, config: Configuration,
               completion: @escaping (Result<String?, Error>) -> Void) throws {
        guard let manifest = Bundle.main.url(forResource: "ApprovedInference", withExtension: "json") else {
            throw AppFailure("Local inference approval is missing. Use the built Whisper.app bundle.")
        }
        let approval = try InferenceApproval.load(from: manifest)
        try approval.validate(cli: config.cliPath, model: config.modelPath, workingDirectory: directory)
        let recording = try AVAudioFile(forReading: audio)
        guard InferenceAudioPolicy.accepts(sampleRate: recording.processingFormat.sampleRate,
            channels: recording.processingFormat.channelCount, frames: recording.length) else {
            throw AppFailure("Speak for at least half a second. Audio must be mono 16 kHz and no longer than 60 seconds.")
        }
        guard FileManager.default.isExecutableFile(atPath: config.cliPath),
              !config.modelPath.isEmpty, FileManager.default.fileExists(atPath: config.modelPath) else {
            throw AppFailure("Select a reviewed whisper-cli executable and model in Settings.")
        }
        let task = Process(); task.executableURL = URL(fileURLWithPath: config.cliPath)
        let output = directory.appendingPathComponent("transcript")
        task.arguments = ["-m", config.modelPath, "-f", audio.path, "-l", "en", "-otxt", "-of", output.path, "-np", "-nt"]
        // Do not inherit credential-bearing environment or an arbitrary PATH.
        task.currentDirectoryURL = directory
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path,
                            "TMPDIR": directory.path, "OMP_TOOL": "disabled"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice // No content-bearing diagnostics retained in prototype.
        cancelled = false; timedOut = false
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                self.deadline?.cancel(); self.deadline = nil; self.process = nil
                if self.cancelled { completion(.failure(AppFailure("Cancelled."))); return }
                if self.timedOut { completion(.failure(AppFailure("Transcription timed out."))); return }
                guard task.terminationStatus == 0 else {
                    completion(.failure(AppFailure("Whisper exited with status \(task.terminationStatus). Check approved tool/model compatibility."))); return
                }
                do {
                    let path = output.appendingPathExtension("txt")
                    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                    guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else {
                        throw AppFailure("Transcript output exceeded the size limit.")
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    completion(.success(Transcript.normalize(try String(contentsOf: path, encoding: .utf8))))
                } catch { completion(.failure(error)) }
            }
        }
        try task.run(); process = task
        let timeout = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task, task.isRunning else { return }
            self.timedOut = true; self.terminate(task)
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + config.transcriptionTimeout, execute: timeout)
    }

    func cancel() {
        cancelled = true; deadline?.cancel()
        if let process { terminate(process) }
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    var isRunning: Bool { process?.isRunning == true }
}
