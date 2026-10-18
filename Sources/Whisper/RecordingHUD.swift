import AppKit
import QuartzCore
import WhisperCore
import WhisperCapture

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
    private let waveform = TransparentHUDCanvas(frame: NSRect(x: 0, y: 0, width: 152, height: 44))
    private let ring = NSProgressIndicator()
    private let bars = (0..<7).map { _ in CAShapeLayer() }
    private var screenID: CGDirectDisplayID?
    private var visibility = HUDVisibility()
    private var level: CGFloat = 0
    private var displayedLevel: CGFloat = 0.015
    private var displayTimer: Timer?
    private var previousFrameTime: CFTimeInterval = 0
    private static let width: CGFloat = 152
    private static let height: CGFloat = 44
    private static let size = NSSize(width: width, height: height)
    private var compact = false
    private var spinnerAnimating = false

    init() {
        let bounds = NSRect(origin: .zero, size: Self.size)
        panel = IndicatorPanel(contentRect: bounds,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        // The panel shadow follows its rectangular window bounds, creating a dark
        // halo outside the rounded material. Let the material define the edge.
        panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false; panel.level = .floating
        panel.animationBehavior = .none; panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let canvas = TransparentHUDCanvas(frame: bounds)
        canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = canvas

        material.frame = bounds.insetBy(dx: 1, dy: 1)
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true
        material.layer?.backgroundColor = NSColor.clear.cgColor
        material.layer?.cornerRadius = Self.height / 2
        material.layer?.masksToBounds = true
        canvas.addSubview(material)
        waveform.wantsLayer = true; waveform.layer?.backgroundColor = NSColor.clear.cgColor
        canvas.addSubview(waveform)
        ring.frame = NSRect(x: 68, y: 14, width: 16, height: 16)
        ring.style = .spinning; ring.controlSize = .small
        ring.isDisplayedWhenStopped = false
        material.addSubview(ring)

        for (index, bar) in bars.enumerated() {
            bar.fillColor = NSColor.labelColor.cgColor
            bar.cornerRadius = 2
            // Keep waveform above NSVisualEffectView's compositor-managed surface;
            // sublayers attached to that view can be obscured by its backdrop rendering.
            waveform.layer?.addSublayer(bar)
            setBar(bar, index: index, level: 0.015)
        }
    }

    func begin(on screen: NSScreen?) {
        screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        position()
    }

    private func startDisplayUpdates() {
        guard displayTimer == nil else { return }
        previousFrameTime = 0
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.renderLatestLevel()
        }
    }

    private func stopDisplayUpdates() {
        displayTimer?.invalidate()
        displayTimer = nil
        previousFrameTime = 0
    }

    private func renderLatestLevel() {
        guard panel.isVisible, !compact else { stopDisplayUpdates(); return }
        let now = CACurrentMediaTime()
        let delta = previousFrameTime == 0 ? 1.0 / 60.0 : min(0.05, now - previousFrameTime)
        previousFrameTime = now
        let target = CGFloat(whisper_level_load())
        // Exponential response is frame-rate independent: quick attack, relaxed release.
        displayedLevel = CGFloat(whisper_level_step(Double(displayedLevel), Double(target), delta))
        level = displayedLevel
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() { setBar(bar, index: index, level: level) }
        CATransaction.commit()
    }

    private func setBar(_ bar: CAShapeLayer, index: Int, level: CGFloat) {
        // A fixed center-weighted silhouette keeps the center tallest at every
        // input level; the same restrained amplitude change moves all bars in sync.
        let envelope: CGFloat = [0.42, 0.68, 0.86, 1, 0.86, 0.68, 0.42][index]
        let halfHeight = envelope * (CGFloat(2) + min(level, 0.55) * 8)
        let x = CGFloat(49 + index * 8)
        // One capsule is mirrored around the centerline, so both lobes always
        // represent the same live microphone amplitude.
        let frame = CGRect(x: x + 1, y: Self.height / 2 - halfHeight, width: 4, height: halfHeight * 2)
        bar.frame = frame
        bar.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                          cornerWidth: 2, cornerHeight: 2, transform: nil)
    }

    func show(_ phase: Phase, enabled: Bool) {
        guard enabled, phase != .idle else { hide(); return }
        position(); configure(phase)
        setCompact(phase == .stopping || phase == .transcribing || phase == .delivering)
        if phase == .recording { startDisplayUpdates() } else { stopDisplayUpdates() }
        if let generation = visibility.request(visible: true) {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless() // Never activate or make key.
            fade(to: 1, duration: 0.16, generation: generation)
        }
    }

    private func configure(_ phase: Phase) {
        let workspace = NSWorkspace.shared
        material.layer?.backgroundColor = workspace.accessibilityDisplayShouldReduceTransparency
            ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
        material.state = workspace.accessibilityDisplayShouldReduceTransparency ? .inactive : .active
        bars.forEach { $0.isHidden = phase == .idle || phase == .starting }
        if phase == .recording { displayedLevel = level }
        let shouldAnimateSpinner = phase == .transcribing
            && !workspace.accessibilityDisplayShouldReduceMotion
        if shouldAnimateSpinner != spinnerAnimating {
            spinnerAnimating = shouldAnimateSpinner
            if spinnerAnimating { ring.startAnimation(nil) }
            else { ring.stopAnimation(nil) }
        }
    }

    private func setCompact(_ value: Bool) {
        guard compact != value else { return }
        compact = value
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
        let width = value ? Self.height : Self.width
        let origin = panel.frame.origin
        let frame = NSRect(x: origin.x + (panel.frame.width - width) / 2, y: origin.y,
                           width: width, height: Self.height)
        let materialFrame = NSRect(origin: .zero, size: frame.size).insetBy(dx: 1, dy: 1)
        let radius = Self.height / 2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
            material.animator().frame = materialFrame
            material.animator().layer?.cornerRadius = radius
            ring.animator().frame = value
                ? NSRect(x: 13, y: 13, width: 18, height: 18)
                : NSRect(x: 68, y: 14, width: 16, height: 16)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        bars.forEach { $0.opacity = value ? 0 : 1 }
        CATransaction.commit()
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
        let currentWidth = panel.frame.width > 0 ? panel.frame.width : Self.size.width
        panel.setFrameOrigin(NSPoint(x: frame.midX - currentWidth / 2, y: frame.minY + 24))
    }

    func hide(immediately: Bool = false) {
        stopDisplayUpdates()
        if spinnerAnimating {
            spinnerAnimating = false
            ring.stopAnimation(nil)
        }
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
        level = 0.8
        // Preview checks keep the waveform centered, visible, and proportionate
        // to the tightened pill rather than merely checking PNG encoding.
        func frames(at level: CGFloat) -> [CGRect] {
            for (index, bar) in bars.enumerated() { setBar(bar, index: index, level: level) }
            return bars.map(\.frame)
        }
        let quietFrames = frames(at: 0)
        let moderateFrames = frames(at: 0.25)
        let loudFrames = frames(at: 1)
        let barFrames = loudFrames
        let widths = barFrames.map(\.width)
        let gaps = zip(barFrames, barFrames.dropFirst()).map { $1.minX - $0.maxX }
        let silhouettes = [quietFrames, moderateFrames, loudFrames]
        let centerDominates = silhouettes.allSatisfy { frame in
            frame[3].height > frame[2].height && frame[3].height > frame[4].height
                && frame[2].height > frame[1].height && frame[4].height > frame[5].height
        }
        let sameLayout = zip(quietFrames, loudFrames).allSatisfy {
            $0.width == $1.width && $0.midX == $1.midX
        }
        let centered = abs(barFrames.map(\.midX).reduce(0, +) / CGFloat(barFrames.count) - Self.width / 2) < 1
        guard barFrames.count == 7,
              barFrames.allSatisfy({ !$0.isEmpty && $0.minX >= 0 && $0.maxX <= Self.width
                  && $0.minY >= 0 && $0.maxY <= Self.height }),
              widths.allSatisfy({ $0 == 4 }), gaps.allSatisfy({ $0 == 4 }), centered,
              centerDominates, sameLayout,
              quietFrames[3].height < moderateFrames[3].height,
              moderateFrames[3].height < loudFrames[3].height,
              loudFrames[3].height <= 13 else {
            throw AppFailure("HUD waveform geometry, hierarchy, or level bounds are invalid.")
        }
        material.state = .inactive
        material.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let canvas = panel.contentView,
              let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw AppFailure("HUD preview unavailable.")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let scaleX = Self.size.width / CGFloat(bitmap.pixelsWide)
        let scaleY = Self.size.height / CGFloat(bitmap.pixelsHigh)
        let outerRadius = Self.height / 2 + 1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let px = (CGFloat(x) + 0.5) * scaleX
                let py = (CGFloat(y) + 0.5) * scaleY
                let dx = max(0, abs(px - Self.size.width / 2) - (Self.size.width / 2 - outerRadius))
                let dy = py - Self.size.height / 2
                // Allow one logical pixel for rounded-capsule edge antialiasing.
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
