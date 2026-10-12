import AppKit
import AVFoundation
import ApplicationServices
import Darwin
import WhisperCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let resultLine = NSMenuItem(title: "Copy-only prototype", action: nil, keyEquivalent: "")
    private var cancelItem: NSMenuItem!, copyItem: NSMenuItem!
    private let hotkey = HotkeyController()
    private let hud = RecordingHUD()
    private let settings = SettingsController()
    private let delivery = TargetDelivery()
    private var config = Configuration()
    private var jobConfig = Configuration()
    private var gate = JobGate()
    private var recorder: NativeRecorder?
    private var transcriber: Transcriber?
    private var directory: URL?
    private var jobFiles: JobFiles?
    private var target: TargetSnapshot?
    private var targetChanged = false
    private var maxTimer: Timer?, focusTimer: Timer?, startupTimer: Timer?
    private var lastTranscript: String?
    private var observers: [NSObjectProtocol] = []
    private var quitting = false
    private var cancelling = false
    private var lockFD: Int32 = -1
    private var shortcutRecording = false
    private var shortcutRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Whisper", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            lockFD = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("Whisper-TemporaryJobs", isDirectory: true)
            jobFiles = try JobFiles(root: temporaryRoot)
            try jobFiles?.removeRecognizedJobs()
            // Migrate away from durable Application Support audio storage. The
            // instance lock is already held; only marked jobs owned by us qualify.
            let legacyRoot = support.appendingPathComponent("TemporaryJobs", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacyRoot.path) {
                try JobFiles(root: legacyRoot).removeRecognizedJobs()
            }
        } catch { NSApp.terminate(nil); return }
        if let data = UserDefaults.standard.data(forKey: "configuration"),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data) { config = saved }
        config.validate()
        if let url = Bundle.main.url(forResource: "ApprovedInference", withExtension: "json"),
           let approval = try? InferenceApproval.load(from: url), approval.approvedForLocalTesting {
            if config.cliPath.isEmpty { config.cliPath = approval.cliPath }
            if config.modelPath.isEmpty { config.modelPath = approval.modelPath }
        }
        if UserDefaults.standard.integer(forKey: "shortcutDefaultsVersion") < 1 {
            if config.keyCode == 49 && config.modifiers == 0xC0000 {
                config.keyCode = Shortcut.defaultKey; config.modifiers = Shortcut.defaultModifiers
            }
            UserDefaults.standard.set(1, forKey: "shortcutDefaultsVersion")
            UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: "configuration")
            UserDefaults.standard.removeObject(forKey: "shortcutLabel")
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: "configuration")
        TargetSnapshot.prepareAccessibility()
        buildMenu(); bindShortcut()
        hotkey.onPress = { [weak self] in self?.start() }
        hotkey.onRelease = { [weak self] in self?.stop() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        settings.onSave = { [weak self] config in
            guard let self else { return "App unavailable." }
            guard self.gate.phase == .idle else { return "Finish or cancel dictation before changing settings." }
            let shortcutChanged = self.config.keyCode != config.keyCode || self.config.modifiers != config.modifiers
            self.config = config
            UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: "configuration")
            if shortcutChanged { self.bindShortcut() }
            return nil
        }
        settings.onPermission = { [weak self] in self?.permissionHelp() }
        settings.onEnableShortcut = { [weak self] in self?.enableShortcut() }
        settings.onShortcutRecording = { [weak self] recording in
            guard let self else { return }
            self.shortcutRecording = recording
            if recording { self.hotkey.uninstall() }
            else if !self.quitting { self.bindShortcut() }
        }
        shortcutRetryTimer = commonTimer(interval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.quitting, !self.shortcutRecording else { return }
            if !AXIsProcessTrusted() {
                if self.gate.id != nil { self.cancel(message: "Shortcut permission was removed.") }
                self.hotkey.uninstall()
            } else if self.gate.phase == .idle && !self.hotkey.isInstalled {
                self.bindShortcut()
            }
            self.settings.setShortcutStatus(ready: self.hotkey.isInstalled)
            if self.gate.phase == .idle { self.updateIdleStatus() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hud.hide(immediately: true)
                self?.cancel()
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                TargetSnapshot.prepareAccessibility()
                guard self.gate.phase != .idle else { return }
                if self.target?.matchesCurrent() != true { self.targetChanged = true }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.hud.position() })
        if !AXIsProcessTrusted() { feedback("Enable the dictation shortcut in Settings.") }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Whisper")
        let menu = NSMenu(); menu.addItem(statusLine); menu.addItem(resultLine); menu.addItem(.separator())
        cancelItem = menu.addItem(withTitle: "Cancel Dictation", action: #selector(cancelAction), keyEquivalent: "")
        copyItem = menu.addItem(withTitle: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permission Help…", action: #selector(permissionHelp), keyEquivalent: "")
        menu.addItem(withTitle: "Enable Shortcut…", action: #selector(enableShortcut), keyEquivalent: "")
        menu.addItem(withTitle: "Recheck Shortcut", action: #selector(recheck), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Whisper", action: #selector(quit), keyEquivalent: "q")
        menu.autoenablesItems = false
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu; refresh()
    }

    private func bindShortcut() {
        hotkey.keyCode = config.keyCode; hotkey.modifiers = CGEventFlags(rawValue: config.modifiers)
        if !hotkey.install() { feedback("Shortcut unavailable. Choose Enable Shortcut…") }
        settings.setShortcutStatus(ready: hotkey.isInstalled)
        if gate.phase == .idle { updateIdleStatus() }
    }
    private func updateIdleStatus() {
        if hotkey.secureInputEnabled {
            statusLine.title = "Shortcut paused by secure keyboard input"
        } else {
            statusLine.title = hotkey.isInstalled ? "Ready — hold \(Shortcut.display(key: config.keyCode, modifiers: config.modifiers))" : "Shortcut not enabled"
        }
        statusItem?.button?.toolTip = "Whisper — \(statusLine.title)"
    }
    private func refresh() {
        settings.setBusy(gate.phase != .idle)
        settings.setShortcutStatus(ready: hotkey.isInstalled)
        statusLine.title = gate.phase.label
        statusItem.button?.toolTip = "Whisper — \(gate.phase.label)"
        statusItem.button?.image = NSImage(systemSymbolName: gate.phase == .recording ? "mic.fill" : "mic",
            accessibilityDescription: gate.phase.label)
        cancelItem?.isEnabled = gate.phase != .idle; copyItem?.isEnabled = lastTranscript != nil
        hud.show(gate.phase, enabled: jobConfig.showHUD)
        if gate.phase == .idle { updateIdleStatus() }
    }
    private func feedback(_ text: String) { resultLine.title = text; resultLine.toolTip = text }
    private func commonTimer(interval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func start() {
        guard !quitting, NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let job = gate.begin() else { return }
        cancelling = false; jobConfig = config; target = TargetSnapshot.capture(); targetChanged = false
        hud.begin(on: target?.screen); refresh()
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.gate.owns(job) else { return }
                    // Permission prompts disturb the destination; require a fresh shortcut press.
                    self.finish(message: granted ? "Microphone allowed. Focus your input and try again." : "Microphone denied. Open Permission Help.")
                }
            }
            return
        }
        guard permission == .authorized else { finish(message: "Microphone access denied. Open Permission Help."); return }
        do {
            guard let jobFiles else { throw AppFailure("Private temporary storage unavailable.") }
            let dir = try jobFiles.create()
            directory = dir
            let recorder = NativeRecorder(); self.recorder = recorder
            recorder.onReady = { [weak self] in
                guard let self, self.gate.advance(job, to: .recording) else { return }
                self.startupTimer?.invalidate(); self.startupTimer = nil; self.refresh()
            }
            recorder.onFailure = { [weak self] error in
                guard let self, self.gate.owns(job), !self.cancelling else { return }
                self.cancel(message: error.localizedDescription)
            }
            recorder.onLimit = { [weak self] in
                guard let self, self.gate.owns(job) else { return }
                self.stop()
            }
            try recorder.start(url: dir.appendingPathComponent("recording.wav"), durationLimit: jobConfig.recordingLimit)
            maxTimer = commonTimer(interval: jobConfig.recordingLimit, repeats: false) { [weak self] _ in self?.stop() }
            startupTimer = commonTimer(interval: 5, repeats: false) { [weak self] _ in
                guard let self, self.gate.owns(job), self.gate.phase == .starting else { return }
                self.cancel(message: "Microphone produced no audio. Check the selected system input.")
            }
            focusTimer = commonTimer(interval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.target?.matchesCurrent() != true { self.targetChanged = true }
            }
        } catch { cancel(message: error.localizedDescription) }
    }

    private func stop() {
        guard let job = gate.id, [.starting, .recording].contains(gate.phase) else { return }
        guard recorder != nil else { finish(message: "Recording cancelled before microphone readiness."); return }
        guard gate.advance(job, to: .stopping) else { return }
        maxTimer?.invalidate(); startupTimer?.invalidate(); refresh()
        let error = recorder?.stop(); recorder = nil
        if let error { finish(message: error.localizedDescription); return }
        guard let dir = directory else { finish(message: "Audio directory missing."); return }
        let audio = dir.appendingPathComponent("recording.wav")
        guard let file = try? AVAudioFile(forReading: audio), file.length > 0 else {
            finish(message: "No usable audio captured."); return
        }
        guard gate.advance(job, to: .transcribing) else { return }
        refresh()
        let transcriber = Transcriber(); self.transcriber = transcriber
        do {
            try transcriber.start(audio: audio, directory: dir, config: jobConfig) { [weak self] result in
                guard let self, self.gate.owns(job) else { return }
                self.transcriber = nil
                if self.cancelling { self.finish(message: "Cancelled."); return }
                switch result {
                case .failure(let error): self.finish(message: error.localizedDescription)
                case .success(nil): self.finish(message: "No speech detected.")
                case .success(let text?):
                    self.lastTranscript = text
                    guard self.gate.advance(job, to: .delivering) else { return }
                    self.refresh(); self.deliverWhenModifiersReleased(text, job: job, attempts: 30)
                }
            }
        } catch { self.transcriber = nil; finish(message: error.localizedDescription) }
    }

    private func deliverWhenModifiersReleased(_ text: String, job: UUID, attempts: Int) {
        guard gate.owns(job), !cancelling else { return }
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if !held.isEmpty && attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.deliverWhenModifiersReleased(text, job: job, attempts: attempts - 1)
            }
            return
        }
        var settings = jobConfig
        if !held.isEmpty { settings.automaticPaste = false }
        // Final job/target check and synchronous dispatch; cancellation cannot undo a posted paste.
        let message = delivery.deliver(text, config: settings, target: target, changed: targetChanged)
        finish(message: message)
    }

    private func cancel(message: String = "Cancelled.") {
        guard gate.id != nil else { return }
        cancelling = true; maxTimer?.invalidate(); startupTimer?.invalidate(); hud.hide()
        _ = recorder?.stop(); recorder = nil
        if let transcriber, transcriber.isRunning {
            feedback(message); transcriber.cancel() // Wait for exit before cleanup/new job.
        } else { finish(message: message) }
    }
    private func finish(message: String) {
        maxTimer?.invalidate(); focusTimer?.invalidate(); startupTimer?.invalidate()
        maxTimer = nil; focusTimer = nil; startupTimer = nil
        _ = recorder?.stop(); recorder = nil
        var result = message
        if let directory {
            do { try jobFiles?.remove(directory) }
            catch { result = "Temporary audio cleanup failed. Check \(jobFiles?.root.path ?? "the macOS temporary folder")." }
        }
        directory = nil; transcriber = nil; gate.finish(); target = nil; cancelling = false
        feedback(result); refresh()
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    @objc private func cancelAction() { cancel() }
    @objc private func copyLast() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastTranscript, forType: .string)
        feedback("Last transcript copied.")
    }
    @objc private func openSettings() { settings.show(config) }
    @objc private func recheck() {
        guard gate.phase == .idle, !shortcutRecording else { feedback("Finish recording first."); return }
        bindShortcut()
        if hotkey.isInstalled { feedback("Shortcut enabled. Focus your input and hold \(Shortcut.display(key: config.keyCode, modifiers: config.modifiers)).") }
    }
    @objc private func enableShortcut() {
        guard gate.phase == .idle, !shortcutRecording else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            recheck()
            if !hotkey.isInstalled {
                _ = CGRequestListenEventAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
                feedback("Allow Whisper in Input Monitoring, then quit and reopen the app.")
            }
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        feedback("Allow Whisper in Accessibility. The shortcut will reconnect automatically.")
    }
    @objc private func permissionHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Whisper permissions"
        alert.informativeText = "Allow Whisper in System Settings → Privacy & Security → Microphone and Accessibility. Input Monitoring may also be needed. Then choose Recheck Shortcut. Disable the old Pi voice shortcut before testing."
        alert.addButton(withTitle: "Open Accessibility Settings"); alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shortcutRetryTimer?.invalidate(); shortcutRetryTimer = nil
        hud.hide(immediately: true); hotkey.uninstall()
        if gate.id != nil && transcriber?.isRunning == true {
            quitting = true; cancel(); return .terminateLater
        }
        cancel(); lastTranscript = nil; return .terminateNow
    }
}

@main
struct WhisperMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--permissions-status") {
            print("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not allowed")")
            print("Input Monitoring: \(CGPreflightListenEventAccess() ? "allowed" : "not allowed")")
            print("Secure keyboard input: \(HotkeyController().secureInputEnabled ? "enabled" : "disabled")")
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            print("Microphone: \(microphone == .authorized ? "allowed" : "not allowed")")
            let probe = HotkeyController()
            print("Global shortcut hook: \(probe.install() ? "available" : "unavailable")")
            probe.uninstall() // No run loop or callbacks: this probe never captures keystrokes.
            return
        }
        let inspectionBundle: String?
        if CommandLine.arguments.contains("--inspect-obsidian") { inspectionBundle = "md.obsidian" }
        else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-target" {
            inspectionBundle = CommandLine.arguments[2]
        } else { inspectionBundle = nil }
        if let bundle = inspectionBundle {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
                print("Target app is not running."); return
            }
            let preparation = TargetSnapshot.prepareAccessibility(for: app)
            print("Accessibility preparation result: \(preparation.map { String($0.rawValue) } ?? "not attempted")")
            // Isolated diagnostic only: allow deferred web-content AX activation.
            // Normal recording never waits here; activation is primed on app focus.
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            var focus: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focus)
            if status == .success, let focus, CFGetTypeID(focus) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(focus, to: AXUIElement.self)
                var role: CFTypeRef?, subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                print("Focused role: \(role as? String ?? "unavailable"), subrole: \(subrole as? String ?? "none")")
            } else { print("Focused element unavailable (AX status \(status.rawValue)); focus the intended input for a live check.") }
            if let snapshot = TargetSnapshot.capture(), snapshot.bundle == bundle {
                var stable = true
                for _ in 0..<10 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    if !snapshot.matchesCurrent() { stable = false }
                }
                let eligible = DeliveryPolicy.mayPaste(automatic: true, changed: false, sameTarget: stable,
                    editable: snapshot.editable, terminal: snapshot.terminal, bestEffort: false)
                print("Editable editor: \(snapshot.editable); focus stable for one second: \(stable)")
                print("Automatic-paste eligibility: \(eligible ? "available" : "copy-only fallback")")
            }
            return // Structural metadata only: never reads note text or posts keys.
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-hud" {
            do { try RecordingHUD().renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[2])); print("HUD preview passed transparent-surround and visible-circle checks.") }
            catch { fputs("HUD preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--self-test-capture") {
            do { try NativeRecorder.verifyCapture(); print("Capture regression test passed.") }
            catch { fputs("Capture test failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--self-test-inference") {
            InferenceSmokeTest.run()
            return
        }
        if CommandLine.arguments.contains("--self-test-shortcut") {
            do { try SettingsController.verifyShortcutRecorder(); print("Shortcut recorder smoke test passed.") }
            catch { fputs("Shortcut recorder test failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-settings" {
            do { try SettingsController().renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { fputs("Settings preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let delegate = AppDelegate(); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
