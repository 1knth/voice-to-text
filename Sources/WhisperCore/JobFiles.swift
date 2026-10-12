import Foundation
import Darwin

public struct JobFiles {
    public let root: URL
    private static let marker = "Whisper private temporary job v1\n"
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try validate(root, expected: .typeDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func validate(_ url: URL, expected: FileAttributeType) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expected,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    public func create() throws -> URL {
        try validate(root, expected: .typeDirectory)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            let marker = directory.appendingPathComponent(".whisper-job")
            try Self.marker.write(to: marker, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    private func validateJob(_ directory: URL) throws {
        guard directory.standardizedFileURL.deletingLastPathComponent().path == root.path,
              UUID(uuidString: directory.lastPathComponent) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        try validate(root, expected: .typeDirectory)
        try validate(directory, expected: .typeDirectory)
        let marker = directory.appendingPathComponent(".whisper-job")
        try validate(marker, expected: .typeRegular)
        let attrs = try FileManager.default.attributesOfItem(atPath: marker.path)
        guard (attrs[.size] as? NSNumber)?.intValue == Self.marker.utf8.count,
              try String(contentsOf: marker, encoding: .utf8) == Self.marker else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
    public func remove(_ directory: URL) throws {
        try validateJob(directory)
        try FileManager.default.removeItem(at: directory)
    }
    /// Startup-only cleanup after acquiring the app's exclusive instance lock.
    /// Deletes fresh crash leftovers too, but never unrelated/unmarked entries.
    public func removeRecognizedJobs() throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard (try? validateJob(directory)) != nil else { continue }
            try remove(directory)
        }
    }
    public func removeStale(olderThan cutoff: Date) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard (try? validateJob(directory)) != nil else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            if let date = attrs[.modificationDate] as? Date, date < cutoff { try remove(directory) }
        }
    }
}
