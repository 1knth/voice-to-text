import AppKit
import ApplicationServices
import Carbon
import WhisperCore

final class HotkeyController {
    var onPress: ((DictationAction) -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var keyCode: UInt16 = 2
    var modifiers: CGEventFlags = [.maskAlternate]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var swallowed = false
    private var activeKeyCode: UInt16 = 2
    private var activeModifiers: CGEventFlags = []
    private static let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }
    var isInstalled: Bool {
        guard let tap, CFMachPortIsValid(tap) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func install() -> Bool {
        uninstall()
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyController>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; held = false; swallowed = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            held = false
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp && code == activeKeyCode && swallowed {
            swallowed = false
            if held { held = false; DispatchQueue.main.async { [weak self] in self?.onRelease?() } }
            return nil
        }
        if held && type == .keyDown && code == 53 {
            held = false
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return nil
        }
        if held && type == .flagsChanged && event.flags.intersection(Self.relevant) != activeModifiers {
            held = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
        if type == .keyDown {
            if swallowed && code == activeKeyCode { return nil }
            let pressedModifiers = event.flags.intersection(Self.relevant)
            let delivery = Shortcut.fixedAction(key: code, modifiers: pressedModifiers.rawValue)
            if delivery != nil || (code == keyCode && pressedModifiers == modifiers) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    held = true; swallowed = true
                    activeKeyCode = code; activeModifiers = pressedModifiers
                    DispatchQueue.main.async { [weak self] in self?.onPress?(delivery ?? .configured) }
                }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
