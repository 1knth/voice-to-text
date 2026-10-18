import AppKit
import ApplicationServices
import WhisperCore

struct TargetSnapshot {
    let pid: pid_t
    let bundle: String
    let element: AXUIElement?
    let editable: Bool
    let terminal: Bool

    private static var accessibilityPrepared: Set<pid_t> = []

    /// Electron documents this attribute for native assistive clients. Enable
    /// Obsidian's runtime AX tree, not a vault preference or a blanket paste bypass.
    @discardableResult
    static func prepareAccessibility(for app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> AXError? {
        guard let app, app.bundleIdentifier == "md.obsidian", AXIsProcessTrusted() else { return nil }
        if accessibilityPrepared.contains(app.processIdentifier) { return .success }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        // A standard root-role query also activates native AX support in newer
        // Electron/Chromium builds; complete-mode activation can be deferred.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &role)
        let result = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFTypeRef)
        if result == .success || result == .attributeUnsupported {
            accessibilityPrepared.insert(app.processIdentifier)
        }
        return result
    }

    static func capture() -> TargetSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
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
    func deliver(_ text: String, config: Configuration, target: TargetSnapshot?, changed: Bool) -> String {
        let paste = DeliveryPolicy.mayPaste(automatic: config.automaticPaste, changed: changed,
            sameTarget: target?.matchesCurrent() == true, editable: target?.editable == true,
            terminal: target?.terminal == true, bestEffort: config.terminalBestEffort)
            && AXIsProcessTrusted()
        let board = NSPasteboard.general
        // Prototype preserves plain text only; unsupported/multi-format contents are not read.
        let oldItems = board.pasteboardItems ?? []
        let oldText: String? = config.preserveClipboard && paste && oldItems.count == 1
            && oldItems[0].types == [.string]
            ? board.string(forType: .string).flatMap { $0.utf8.count <= 1_048_576 ? $0 : nil } : nil
        let marker = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType("local.whisper.clipboard-owner")
        board.clearContents()
        guard board.setString(text, forType: .string) else { return "Clipboard write failed. Use Copy Last Transcript to retry." }
        guard paste else {
            if !config.automaticPaste { return "Transcript copied — paste manually into your intended input." }
            if changed || target?.matchesCurrent() != true { return "Focus changed or could not be verified — transcript copied." }
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
        board.setString(marker, forType: markerType)
        let count = board.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        if let oldText {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard board.changeCount == count, board.string(forType: markerType) == marker else { return }
                board.clearContents(); board.setString(oldText, forType: .string)
            }
        }
        return "Paste attempted — review before submitting."
    }
}
