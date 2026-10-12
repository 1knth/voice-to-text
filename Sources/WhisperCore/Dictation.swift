import Foundation

public enum Phase: String {
    case idle, starting, recording, stopping, transcribing, delivering
    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting microphone…"
        case .recording: return "Recording — release shortcut to finish"
        case .stopping: return "Finishing recording…"
        case .transcribing: return "Transcribing locally…"
        case .delivering: return "Preparing transcript…"
        }
    }
}

/// Main-thread owned in the app; all asynchronous results must carry their job ID.
public struct JobGate {
    public private(set) var id: UUID?
    public private(set) var phase: Phase = .idle
    public init() {}
    public mutating func begin() -> UUID? {
        guard id == nil else { return nil }
        let newID = UUID(); id = newID; phase = .starting; return newID
    }
    @discardableResult public mutating func advance(_ job: UUID, to next: Phase) -> Bool {
        guard id == job else { return false }
        let allowed: [Phase: Set<Phase>] = [
            .starting: [.recording, .stopping], .recording: [.stopping],
            .stopping: [.transcribing], .transcribing: [.delivering]
        ]
        guard allowed[phase]?.contains(next) == true else { return false }
        phase = next; return true
    }
    public func owns(_ job: UUID) -> Bool { id == job }
    public mutating func finish() { id = nil; phase = .idle }
}

public struct Configuration: Codable {
    public var cliPath = ""
    public var modelPath = ""
    public var automaticPaste = false
    public var preserveClipboard = false
    public var terminalBestEffort = false
    public var showHUD = true
    public var recordingLimit = 60.0
    public var transcriptionTimeout = 120.0
    public var keyCode: UInt16 = Shortcut.defaultKey
    public var modifiers: UInt64 = Shortcut.defaultModifiers
    public init() {}
    public mutating func validate() {
        recordingLimit = recordingLimit.isFinite ? min(60, max(5, recordingLimit)) : 60
        transcriptionTimeout = transcriptionTimeout.isFinite ? min(300, max(10, transcriptionTimeout)) : 120
        modifiers &= Shortcut.modifierMask
        if !Shortcut.isValid(key: keyCode, modifiers: modifiers) {
            keyCode = Shortcut.defaultKey; modifiers = Shortcut.defaultModifiers
        }
    }
}

public enum Transcript {
    public static func normalize(_ raw: String) -> String? {
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, !["[BLANK_AUDIO]", "[NO_SPEECH]"].contains(text.uppercased()) else { return nil }
        return text
    }
}

public struct DeliveryPolicy {
    public static func mayPaste(automatic: Bool, changed: Bool, sameTarget: Bool,
                                editable: Bool, terminal: Bool, bestEffort: Bool) -> Bool {
        guard automatic, !changed, sameTarget else { return false }
        return terminal ? bestEffort : editable
    }
}
