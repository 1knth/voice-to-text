import AppKit
import ApplicationServices
import Carbon
import WhisperCore

struct TargetSnapshot {
    let pid: pid_t
    let bundle: String
    let element: AXUIElement?
    let editable: Bool
    let terminal: Bool

    private static var accessibilityPrepared: Set<pid_t> = []
    private static let accessibilityLock = NSLock()

    /// Electron documents this attribute for native assistive clients. Enable
    /// Obsidian's runtime AX tree, not a vault preference or a blanket paste bypass.
    @discardableResult
    static func prepareAccessibility(for app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> AXError? {
        guard let app, app.bundleIdentifier == "md.obsidian", AXIsProcessTrusted() else { return nil }
        accessibilityLock.lock()
        let alreadyPrepared = accessibilityPrepared.contains(app.processIdentifier)
        accessibilityLock.unlock()
        if alreadyPrepared { return .success }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        // A standard root-role query also activates native AX support in newer
        // Electron/Chromium builds; complete-mode activation can be deferred.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &role)
        let result = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFTypeRef)
        if result == .success || result == .attributeUnsupported {
            accessibilityLock.lock()
            accessibilityPrepared.insert(app.processIdentifier)
            accessibilityLock.unlock()
        }
        return result
    }

    static func capture(frontmostApplication app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> TargetSnapshot? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        prepareAccessibility(for: app)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var value: CFTypeRef?
        var element: AXUIElement?
        if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            element = unsafeBitCast(value, to: AXUIElement.self)
        }
        var role: CFTypeRef?, subrole: CFTypeRef?
        if let element {
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        }
        let bundle = app.bundleIdentifier ?? ""
        let terminal = ["ghostty", "terminal", "iterm", "warp"].contains { bundle.lowercased().contains($0) }
        let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "")
            && subrole as? String != kAXSecureTextFieldSubrole
        return TargetSnapshot(pid: app.processIdentifier, bundle: bundle,
                              element: element, editable: editable, terminal: terminal)
    }

    func matchesCurrent() -> Bool {
        guard let current = Self.capture(), current.pid == pid else { return false }
        if let a = element, let b = current.element { return CFEqual(a, b) }
        return terminal && current.terminal
    }

    var screen: NSScreen? {
        if let element {
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let axWindow = unsafeBitCast(window, to: AXUIElement.self)
                var pos: CFTypeRef?; var size: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &pos)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &size)
                if let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var p = CGPoint.zero; var s = CGSize.zero
                    AXValueGetValue(unsafeBitCast(pos, to: AXValue.self), .cgPoint, &p)
                    AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s)
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let center = NSPoint(x: p.x + s.width / 2, y: top - p.y - s.height / 2)
                    if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
                }
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

final class TargetDelivery {
    private let typingQueue = DispatchQueue(label: "local.whisper.typing", qos: .userInteractive)

    /// Calls `completion` on the main thread with a status message.
    func deliver(_ text: String, config: Configuration, target: TargetSnapshot?, changed: Bool,
                 globalPaste: Bool = false, completion: @escaping (String) -> Void) {
        if let message = deliverImmediately(text, config: config, target: target, changed: changed,
                                            globalPaste: globalPaste, completion: completion) {
            completion(message)
        }
    }

    /// Returns nil when delivery continues asynchronously and will call `completion` itself.
    private func deliverImmediately(_ text: String, config: Configuration, target: TargetSnapshot?, changed: Bool,
                                    globalPaste: Bool, completion: @escaping (String) -> Void) -> String? {
        let trusted = AXIsProcessTrusted()
        let sameTarget = config.automaticPaste && !globalPaste && !changed && trusted
            && target?.matchesCurrent() == true
        let paste = DeliveryPolicy.mayPaste(automatic: config.automaticPaste, changed: changed,
            sameTarget: sameTarget, editable: target?.editable == true,
            terminal: target?.terminal == true, bestEffort: config.terminalBestEffort, global: globalPaste)
            && trusted
        let board = NSPasteboard.general
        if paste && config.directTyping {
            // Secure input drops synthetic keys, including Cmd+V, so copy instead.
            if IsSecureEventInputEnabled() {
                board.clearContents(); board.setString(text, forType: .string)
                return "Secure input is active — transcript copied."
            }
            // Keystrokes post off the main thread so the HUD keeps animating.
            typingQueue.async { [self] in
                let typed = type(text)
                DispatchQueue.main.async {
                    guard typed else {
                        board.clearContents(); board.setString(text, forType: .string)
                        completion("Typing could not be dispatched — transcript copied."); return
                    }
                    completion("Typed into the focused app — review before submitting.")
                }
            }
            return nil
        }
        let oldText = config.preserveClipboard && paste ? restorableText(from: board) : nil
        board.clearContents()
        guard board.setString(text, forType: .string) else { return "Clipboard write failed. Use Copy Last Transcript to retry." }
        guard paste else {
            if !config.automaticPaste { return "Transcript copied — paste manually into your intended input." }
            if !trusted { return "Enable Whisper in Accessibility to send Cmd+V. Transcript copied." }
            if !sameTarget { return "Focus changed or could not be verified — transcript copied." }
            if target?.terminal == true && !config.terminalBestEffort {
                return "Terminal paste is disabled — enable Allow terminal paste in Settings. Transcript copied."
            }
            if target?.editable != true && target?.terminal != true { return "No editable input detected — transcript copied. Focus an editor and try again." }
            return "Automatic paste unavailable — transcript copied."
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return "Paste could not be dispatched. Transcript remains on clipboard."
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        if let oldText { restoreClipboard(oldText, on: board) }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return "Paste attempted — review before submitting."
    }

    /// Posts the text as Unicode keystrokes so the clipboard is never touched.
    private func type(_ text: String) -> Bool {
        // A private source keeps physically held modifiers out of the typed text.
        let source = CGEventSource(stateID: .privateState)
        for chunk in DeliveryPolicy.typingChunks(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            }
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            usleep(2_000) // Let the target drain its queue so chunks stay in order.
        }
        return true
    }

    private func restorableText(from board: NSPasteboard) -> String? {
        // Preserve only a single plain-text item, up to 1 MiB.
        guard let items = board.pasteboardItems, items.count == 1,
              items[0].types == [.string], let text = board.string(forType: .string),
              text.utf8.count <= 1_048_576 else { return nil }
        return text
    }

    private func restoreClipboard(_ text: String, on board: NSPasteboard) {
        let marker = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType("local.whisper.clipboard-owner")
        board.setString(marker, forType: markerType)
        let count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard board.changeCount == count, board.string(forType: markerType) == marker else { return }
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }
}
