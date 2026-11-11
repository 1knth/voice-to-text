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

/// Vsync-aligned frame callbacks; falls back to a common-mode timer before macOS 14.
private final class FrameTicker: NSObject {
    private let tick: () -> Void
    private var stopLink: (() -> Void)?
    init(view: NSView, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if #available(macOS 14, *) {
            let link = view.displayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            stopLink = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.fire() }
            RunLoop.main.add(timer, forMode: .common)
            stopLink = { timer.invalidate() }
        }
    }
    @objc private func fire() { tick() }
    func invalidate() { stopLink?(); stopLink = nil }
}

final class RecordingHUD {
    private let panel: IndicatorPanel
    private let material = NSVisualEffectView()
    private let waveform = TransparentHUDCanvas(frame: NSRect(x: 0, y: 0, width: 152, height: 44))
    private let ring = NSProgressIndicator()
    private let bars = (0..<7).map { _ in CALayer() }
    private var screenID: CGDirectDisplayID?
    private var visibility = HUDVisibility()
    private var level: CGFloat = 0
    private var displayedLevel: CGFloat = 0.015
    private var ticker: FrameTicker?
    private var previousFrameTime: CFTimeInterval = 0
    /// Recent levels; outer bars replay older samples so motion ripples outward.
    private var history: [(time: CFTimeInterval, level: CGFloat)] = []
    private static let rippleDelay: CFTimeInterval = 0.055
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
        ring.frame = NSRect(x: 67, y: 13, width: 16, height: 16)
        ring.style = .spinning; ring.controlSize = .small
        ring.isDisplayedWhenStopped = false
        material.addSubview(ring)

        for (index, bar) in bars.enumerated() {
            bar.backgroundColor = NSColor.labelColor.cgColor
            bar.cornerRadius = 2.5
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
        guard ticker == nil else { return }
        previousFrameTime = 0; history.removeAll()
        ticker = FrameTicker(view: waveform) { [weak self] in self?.renderLatestLevel() }
    }

    private func stopDisplayUpdates() {
        ticker?.invalidate()
        ticker = nil
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
        history.append((now, level))
        let horizon = now - Self.rippleDelay * 4
        if let stale = history.firstIndex(where: { $0.time >= horizon }), stale > 1 { history.removeFirst(stale - 1) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let delayed = now - Self.rippleDelay * CFTimeInterval(abs(index - bars.count / 2))
            let sample = history.last(where: { $0.time <= delayed })?.level ?? history.first?.level ?? level
            setBar(bar, index: index, level: sample)
        }
        CATransaction.commit()
    }

    private func setBar(_ bar: CALayer, index: Int, level: CGFloat) {
        // A fixed center-weighted silhouette keeps the center tallest at every
        // input level; the same restrained amplitude change moves all bars in sync.
        let envelope: CGFloat = [0.42, 0.68, 0.86, 1, 0.86, 0.68, 0.42][index]
        let halfHeight = envelope * (CGFloat(3) + min(level, 0.55) * 14)
        let x = CGFloat(44 + index * 10)
        // Rounded layer bounds avoid rebuilding a CGPath on every display tick.
        let frame = CGRect(x: x, y: Self.height / 2 - halfHeight, width: 5, height: halfHeight * 2)
        // Bounds and position stay valid while the compact morph scales the bar.
        bar.bounds = CGRect(origin: .zero, size: frame.size)
        bar.position = CGPoint(x: frame.midX, y: frame.midY)
        bar.cornerRadius = 2.5
    }

    func show(_ phase: Phase, enabled: Bool) {
        guard enabled, phase != .idle else { hide(); return }
        position(); configure(phase)
        // Reopen in the full HUD geometry before fading in. Otherwise the previous
        // compact state animates from a circle while the panel is already visible.
        setCompact(phase == .stopping || phase == .transcribing || phase == .delivering,
                   animated: panel.isVisible)
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
        bars.forEach { $0.isHidden = phase == .idle }
        if phase == .recording { displayedLevel = level }
        let shouldAnimateSpinner = phase == .transcribing
            && !workspace.accessibilityDisplayShouldReduceMotion
        if shouldAnimateSpinner != spinnerAnimating {
            spinnerAnimating = shouldAnimateSpinner
            if spinnerAnimating { ring.startAnimation(nil) }
            else { ring.stopAnimation(nil) }
        }
    }

    private func setCompact(_ value: Bool, animated: Bool = true) {
        guard compact != value else { return }
        compact = value
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 0
        // Resizing a window animates in the window server and stutters. The panel
        // keeps its full size; only layer-backed views inside it morph.
        let width = value ? Self.height : Self.width
        let materialFrame = NSRect(x: (Self.width - width) / 2, y: 0, width: width, height: Self.height)
            .insetBy(dx: 1, dy: 1)
        let spring = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = spring
            context.allowsImplicitAnimation = true
            material.animator().frame = materialFrame
            ring.animator().frame = value
                ? NSRect(x: (width - 18) / 2 - 1, y: 12, width: 18, height: 18)
                : NSRect(x: 67, y: 13, width: 16, height: 16)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration * 0.6)
        CATransaction.setAnimationTimingFunction(spring)
        bars.forEach { $0.opacity = value ? 0 : 1; $0.transform = value ? CATransform3DMakeScale(0.4, 0.4, 1) : CATransform3DIdentity }
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
        let origin = NSPoint(x: (frame.midX - Self.width / 2).rounded(), y: frame.minY + 24)
        // Moving a visible HUD between screens mid-animation reads as a jump.
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
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
              widths.allSatisfy({ $0 == 5 }), gaps.allSatisfy({ $0 == 5 }), centered,
              centerDominates, sameLayout,
              quietFrames[3].height < moderateFrames[3].height,
              moderateFrames[3].height < loudFrames[3].height,
              loudFrames[3].height <= 22 else {
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
