import AppKit
import QuartzCore
import WhisperCore

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TransparentHUDCanvas: NSView {
    override var isOpaque: Bool { false }
}

final class RecordingHUD {
    private let panel: IndicatorPanel
    private let material = NSVisualEffectView()
    private let image = NSImageView()
    private let ring = NSProgressIndicator()
    private let outline = CAShapeLayer()
    private var screenID: CGDirectDisplayID?
    private var visibility = HUDVisibility()
    private static let diameter: CGFloat = 76
    private static let padding: CGFloat = 10
    private static let size: CGFloat = diameter + 2 * padding

    init() {
        let bounds = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        panel = IndicatorPanel(contentRect: bounds,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        // AppKit's window shadow can outline the rectangular backing surface.
        // Only the explicitly masked material circle and circular stroke draw.
        panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.animationBehavior = .none; panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let canvas = TransparentHUDCanvas(frame: bounds)
        canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = canvas

        material.frame = NSRect(x: Self.padding, y: Self.padding, width: Self.diameter, height: Self.diameter)
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true
        material.layer?.backgroundColor = NSColor.clear.cgColor
        material.layer?.cornerRadius = Self.diameter / 2
        material.layer?.masksToBounds = true
        // Mask the visual-effect surface itself, not only the containing layer.
        // This keeps backdrop blur/tint out of the transparent square corners.
        material.maskImage = NSImage(size: NSSize(width: Self.diameter, height: Self.diameter), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        canvas.addSubview(material)
        image.frame = NSRect(x: 24, y: 24, width: 28, height: 28)
        image.contentTintColor = .labelColor
        material.addSubview(image)
        ring.frame = NSRect(x: 49, y: 10, width: 16, height: 16)
        ring.style = .spinning; ring.controlSize = .small
        ring.isDisplayedWhenStopped = false
        material.addSubview(ring)

        outline.frame = bounds
        outline.path = CGPath(ellipseIn: material.frame.insetBy(dx: 1, dy: 1), transform: nil)
        outline.fillColor = NSColor.clear.cgColor
        outline.lineWidth = 1
        outline.strokeColor = NSColor.separatorColor.cgColor
        canvas.layer?.addSublayer(outline)
    }

    func begin(on screen: NSScreen?) {
        screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        position()
    }

    func show(_ phase: Phase, enabled: Bool) {
        guard enabled, phase != .idle else { hide(); return }
        position(); configure(phase)
        if let generation = visibility.request(visible: true) {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless() // Never activate or make key.
            fade(to: 1, duration: 0.16, generation: generation)
        }
        NSAccessibility.post(element: image, notification: .valueChanged)
    }

    private func configure(_ phase: Phase) {
        let workspace = NSWorkspace.shared
        material.layer?.backgroundColor = workspace.accessibilityDisplayShouldReduceTransparency
            ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
        material.state = workspace.accessibilityDisplayShouldReduceTransparency ? .inactive : .active
        let symbol: String
        switch phase {
        case .starting: symbol = "mic"
        case .recording: symbol = "mic.fill"
        default: symbol = "ellipsis.circle"
        }
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: phase.label)
        image.alphaValue = phase == .starting ? 0.55 : 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.lineWidth = phase == .recording ? 2 : 1
        outline.strokeColor = (phase == .recording
            ? NSColor.controlAccentColor.withAlphaComponent(0.65)
            : NSColor.separatorColor).cgColor
        CATransaction.commit()
        image.setAccessibilityLabel(phase.label)
        if phase == .transcribing && !workspace.accessibilityDisplayShouldReduceMotion {
            ring.startAnimation(nil)
        } else { ring.stopAnimation(nil) }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, generation: UInt64) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: alpha == 1 ? .easeOut : .easeIn)
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            guard let self, self.visibility.shouldHide(completedGeneration: generation) else { return }
            self.panel.orderOut(nil)
        }
    }

    func position() {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size / 2, y: frame.minY + 24 - Self.padding))
    }

    func hide(immediately: Bool = false) {
        ring.stopAnimation(nil)
        if immediately {
            _ = visibility.request(visible: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
            return
        }
        guard let generation = visibility.request(visible: false) else { return }
        fade(to: 0, duration: 0.18, generation: generation)
    }

    /// Offscreen rendering: never shows a panel or activates an app. A solid
    /// preview backing stands in for the live material's compositor-only blur.
    func renderPreview(to url: URL) throws {
        configure(.recording)
        material.state = .inactive
        material.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let canvas = panel.contentView,
              let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw AppFailure("HUD preview unavailable.")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let scaleX = Self.size / CGFloat(bitmap.pixelsWide)
        let scaleY = Self.size / CGFloat(bitmap.pixelsHigh)
        let outerRadius = Self.diameter / 2 + 1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let dx = (CGFloat(x) + 0.5) * scaleX - Self.size / 2
                let dy = (CGFloat(y) + 0.5) * scaleY - Self.size / 2
                // Allow one logical pixel for circular-edge antialiasing.
                guard dx * dx + dy * dy > outerRadius * outerRadius else { continue }
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent < 0.01 else {
                    throw AppFailure("HUD preview has opaque pixels outside the circle.")
                }
            }
        }
        guard let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2),
              center.alphaComponent > 0.1 else { throw AppFailure("HUD preview circle is missing.") }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppFailure("HUD preview encoding failed.")
        }
        try png.write(to: url)
    }
}
