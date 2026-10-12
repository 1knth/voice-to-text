import Foundation
import Carbon

public enum Shortcut {
    public static let modifierMask: UInt64 = 0x1E0000
    public static let defaultKey: UInt16 = 2 // D
    public static let defaultModifiers: UInt64 = 0x80000 // Option
    public static func isValid(key: UInt16, modifiers: UInt64) -> Bool {
        key <= 126 && (modifiers & modifierMask) != 0
            && ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key)
    }
    public static func display(key: UInt16, modifiers: UInt64) -> String {
        let prefix = (modifiers & 0x40000 != 0 ? "⌃" : "")
            + (modifiers & 0x80000 != 0 ? "⌥" : "")
            + (modifiers & 0x20000 != 0 ? "⇧" : "")
            + (modifiers & 0x100000 != 0 ? "⌘" : "")
        let names: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 76: "⌤",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = names[key] { return prefix + name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var dead: UInt32 = 0; var length = 0
                var characters = [UniChar](repeating: 0, count: 16)
                let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &dead, 16, &length, &characters)
                if status == noErr, length > 0 {
                    return prefix + String(utf16CodeUnits: characters, count: Int(length)).uppercased()
                }
            }
        }
        return prefix + "Key \(key)"
    }
}
