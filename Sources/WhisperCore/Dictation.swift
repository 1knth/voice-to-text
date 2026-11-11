import Foundation

/// Serializes blocking recorder lifecycle work so stop cannot overtake setup.
public final class SerialLifecycleQueue {
    private let queue: DispatchQueue
    public init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    public func submit(_ operation: @escaping () -> Void) { queue.async(execute: operation) }
}

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
    public var automaticPaste = true
    /// With automatic delivery, type the transcript as keystrokes instead of using the clipboard.
    public var directTyping = true
    public var preserveClipboard = false
    public var terminalBestEffort = false
    public var showHUD = true
    public var recordingLimit = 60.0
    public var transcriptionTimeout = 120.0
    public var keyCode: UInt16 = Shortcut.defaultKey
    public var modifiers: UInt64 = Shortcut.defaultModifiers
    public init() {}
    /// Missing keys keep their defaults so configurations saved by older builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let d = Configuration()
        cliPath = try value(.cliPath, d.cliPath)
        modelPath = try value(.modelPath, d.modelPath)
        automaticPaste = try value(.automaticPaste, d.automaticPaste)
        directTyping = try value(.directTyping, d.directTyping)
        preserveClipboard = try value(.preserveClipboard, d.preserveClipboard)
        terminalBestEffort = try value(.terminalBestEffort, d.terminalBestEffort)
        showHUD = try value(.showHUD, d.showHUD)
        recordingLimit = try value(.recordingLimit, d.recordingLimit)
        transcriptionTimeout = try value(.transcriptionTimeout, d.transcriptionTimeout)
        keyCode = try value(.keyCode, d.keyCode)
        modifiers = try value(.modifiers, d.modifiers)
    }
    public var deliveryMode: DeliveryMode {
        get { !automaticPaste ? .copy : directTyping ? .type : .paste }
        set { automaticPaste = newValue != .copy; directTyping = newValue != .paste }
    }
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

public enum DeliveryMode: Hashable {
    case type, paste, copy
}

public struct DeliveryPolicy {
    /// Splits text into keystroke payloads of at most `limit` UTF-16 units,
    /// never separating the units of one character (emoji, combining marks).
    public static func typingChunks(_ text: String, limit: Int = 20) -> [[UInt16]] {
        var chunks: [[UInt16]] = [], chunk: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !chunk.isEmpty && chunk.count + units.count > limit { chunks.append(chunk); chunk = [] }
            chunk += units
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
    public static func mayPaste(automatic: Bool, changed: Bool, sameTarget: Bool,
                                editable: Bool, terminal: Bool, bestEffort: Bool, global: Bool = false) -> Bool {
        guard automatic else { return false }
        if global { return true }
        guard !changed, sameTarget else { return false }
        return terminal ? bestEffort : editable
    }
}
