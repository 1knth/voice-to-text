import Foundation
import CryptoKit

public struct ApprovalFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Pins the local artifacts approved for testing; not a malware scanner or sandbox.
public struct InferenceApproval: Codable {
    public struct Artifact: Codable {
        public let path: String
        public let sha256: String
        public init(path: String, sha256: String) { self.path = path; self.sha256 = sha256 }
    }
    public struct Alias: Codable {
        public let path: String
        public let resolvesTo: String
        public init(path: String, resolvesTo: String) { self.path = path; self.resolvesTo = resolvesTo }
    }
    public let schema: Int
    public let approvedForLocalTesting: Bool
    public let cliPath: String
    public let modelPath: String
    public let artifacts: [Artifact]
    public let aliases: [Alias]
    public let backendSearchDirectories: [String]

    public init(schema: Int = 1, approvedForLocalTesting: Bool, cliPath: String, modelPath: String,
                artifacts: [Artifact], aliases: [Alias] = [], backendSearchDirectories: [String] = []) {
        self.schema = schema; self.approvedForLocalTesting = approvedForLocalTesting
        self.cliPath = cliPath; self.modelPath = modelPath; self.artifacts = artifacts
        self.aliases = aliases; self.backendSearchDirectories = backendSearchDirectories
    }
    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func validate(cli: String, model: String, workingDirectory: URL) throws {
        guard schema == 1, approvedForLocalTesting else { throw ApprovalFailure("Local inference approval is missing.") }
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        guard resolved(cli) == resolved(cliPath), resolved(model) == resolved(modelPath) else {
            throw ApprovalFailure("Only the approved whisper-cli and tiny.en model are enabled. Review new artifacts before changing them.")
        }
        guard artifacts.contains(where: { resolved($0.path) == resolved(cliPath) }),
              artifacts.contains(where: { resolved($0.path) == resolved(modelPath) }) else {
            throw ApprovalFailure("Approval manifest does not pin the executable and model.")
        }
        for alias in aliases where resolved(alias.path) != alias.resolvesTo {
            throw ApprovalFailure("Dependency link changed: \(alias.path). Re-review required.")
        }
        for artifact in artifacts {
            guard try Self.digest(URL(fileURLWithPath: artifact.path)) == artifact.sha256 else {
                throw ApprovalFailure("Dependency checksum changed: \(artifact.path). Re-review required.")
            }
        }
        let approved = Set(artifacts.map { resolved($0.path) })
        for directory in backendSearchDirectories + [workingDirectory.path] {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            for file in files where file.hasPrefix("libggml-") && file.hasSuffix(".so") {
                guard approved.contains(resolved((directory as NSString).appendingPathComponent(file))) else {
                    throw ApprovalFailure("Unapproved GGML backend in search directory. Execution blocked.")
                }
            }
        }
    }
}

public enum InferenceAudioPolicy {
    public static func accepts(sampleRate: Double, channels: UInt32, frames: Int64) -> Bool {
        sampleRate == 16000 && channels == 1 && (8000...960000).contains(frames)
    }
}
