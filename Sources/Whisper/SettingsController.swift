import AppKit
import SwiftUI
import AVFoundation
import ApplicationServices
import WhisperCore

/// A real shortcut recorder, not a read-only text field. Captures only while armed.
final class ShortcutRecorderButton: NSButton {
    var onCapture: ((UInt16, UInt64) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var savedTitle = ""
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded; title = "⌥D"
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self; action = #selector(toggleRecording)
        setAccessibilityLabel("Dictation shortcut")
        toolTip = "Click to record a shortcut. Escape cancels."
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    @objc private func toggleRecording() {
        if recording { finish(); return }
        guard let window else { return }
        recording = true; savedTitle = title; title = "Press shortcut…"
        window.makeFirstResponder(self)
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.window else { return event }
            return self.accept(key: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue),
                isRepeat: event.isARepeat) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.finish() }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Returns true only while recording; shared by the monitor and first-party smoke test.
    @discardableResult func accept(key: UInt16, modifiers: UInt64, isRepeat: Bool = false) -> Bool {
        guard recording else { return false }
        if key == 53 { finish(); return true }
        if isRepeat { return true }
        guard Shortcut.isValid(key: key, modifiers: modifiers) else {
            title = "Use a modifier + key"; return true
        }
        finish(); onCapture?(key, modifiers & Shortcut.modifierMask)
        return true
    }
    func updateShortcutTitle(_ label: String) { if !recording { title = label } }
    func finish() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        title = savedTitle; onRecordingChanged?(false)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finish() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

private final class SettingsStore: ObservableObject {
    @Published var configuration = Configuration()
    @Published var error: String?
    @Published var isBusy = false
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
    @Published var shortcutReady = false
    var onSave: ((Configuration) -> String?)?
    var onPermission: (() -> Void)?
    var onEnableShortcut: (() -> Void)?
    var onShortcutRecording: ((Bool) -> Void)?

    func binding<T>(_ path: WritableKeyPath<Configuration, T>) -> Binding<T> {
        Binding(get: { self.configuration[keyPath: path] }, set: { value in
            var next = self.configuration; next[keyPath: path] = value; self.apply(next)
        })
    }
    func apply(_ next: Configuration) {
        var validated = next; validated.validate()
        if let problem = onSave?(validated) { error = problem; return }
        configuration = validated; error = nil
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
    }
    func choose(_ path: WritableKeyPath<Configuration, String>) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            var next = configuration; next[keyPath: path] = url.path; apply(next)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var store: SettingsStore
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        button.onRecordingChanged = { [weak store] recording in store?.onShortcutRecording?(recording) }
        button.onCapture = { [weak store] key, modifiers in
            guard let store else { return }
            var next = store.configuration; next.keyCode = key; next.modifiers = modifiers
            store.apply(next)
        }
        return button
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.updateShortcutTitle(Shortcut.display(key: store.configuration.keyCode, modifiers: store.configuration.modifiers))
    }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.finish() }
}

private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmReset = false
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $tab) {
                Text("General").tag(0)
                Text("Audio").tag(1)
                Text("Advanced").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 350)
            .padding(.top, 20)
            .padding(.bottom, 8)
            Group {
                switch tab {
                case 1: audio
                case 2: advanced
                default: general
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Reset Settings…") { confirmReset = true }
                    .buttonStyle(.link)
                Spacer()
                if let error = store.error {
                    Text(error).foregroundStyle(.red).font(.caption).lineLimit(2)
                } else {
                    Text(store.isBusy ? "Finish dictation to edit settings" : "Changes save automatically")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(store.isBusy)
        .alert("Reset settings?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.apply(Configuration()) }
        } message: { Text("Your shortcut and preferences will return to their defaults.") }
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    ShortcutRecorder(store: store).frame(width: 170, height: 28)
                }
                if !store.shortcutReady {
                    HStack {
                        Label(store.accessibilityAllowed ? "Shortcut unavailable" : "Permission needed",
                            systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(store.accessibilityAllowed ? "Retry" : "Enable Shortcut…") { store.onEnableShortcut?() }
                    }
                }
            } footer: { Text("Hold to speak. Release to finish.") }
            Section("Delivery") {
                Picker("Transcript", selection: store.binding(\.automaticPaste)) {
                    Text("Copy to clipboard").tag(false)
                    Text("Paste automatically").tag(true)
                }
                Toggle("Restore previous clipboard", isOn: store.binding(\.preserveClipboard))
                    .disabled(!store.configuration.automaticPaste)
                    .help("Best-effort plain-text restoration. Copy Last Transcript remains available.")
                Toggle("Allow terminal paste", isOn: store.binding(\.terminalBestEffort))
                    .disabled(!store.configuration.automaticPaste)
                    .help("Terminal tabs and tmux panes cannot be verified. Leave off for strict copy-only behavior.")
            }
            Section("Appearance") {
                Toggle("Show recording indicator", isOn: store.binding(\.showHUD))
            }
        }
        .formStyle(.grouped)
    }
    private var audio: some View {
        Form {
            Section("Recording") {
                LabeledContent("Microphone", value: "System Default")
                Picker("Maximum recording", selection: store.binding(\.recordingLimit)) {
                    ForEach([5.0, 15, 30, 45, 60], id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                    if ![5.0, 15, 30, 45, 60].contains(store.configuration.recordingLimit) {
                        Text("\(Int(store.configuration.recordingLimit)) seconds").tag(store.configuration.recordingLimit)
                    }
                }
            }
            Section("Permissions") {
                LabeledContent("Microphone") { permissionBadge(store.microphoneAllowed) }
                LabeledContent("Accessibility") { permissionBadge(store.accessibilityAllowed) }
                Button("Open Permission Settings…") { store.onPermission?(); store.refreshPermissions() }
            }
            Section {
                LabeledContent("Processing", value: "On this Mac")
                LabeledContent("Language", value: "English")
            }
        }
        .formStyle(.grouped)
    }
    private var advanced: some View {
        Form {
            Section("Transcription") {
                fileRow("Whisper executable", path: \.cliPath)
                fileRow("Model", path: \.modelPath)
                Picker("Timeout", selection: store.binding(\.transcriptionTimeout)) {
                    ForEach([30.0, 60, 120, 180, 300], id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                    if ![30.0, 60, 120, 180, 300].contains(store.configuration.transcriptionTimeout) {
                        Text("\(Int(store.configuration.transcriptionTimeout)) seconds").tag(store.configuration.transcriptionTimeout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    private func fileRow(_ title: String, path: WritableKeyPath<Configuration, String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Text(store.configuration[keyPath: path].isEmpty ? "Not selected" :
                    URL(fileURLWithPath: store.configuration[keyPath: path]).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(store.configuration[keyPath: path])
                Button("Choose…") { store.choose(path) }
            }
        }
    }
    private func permissionBadge(_ allowed: Bool) -> some View {
        Label(allowed ? "Allowed" : "Not allowed", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(allowed ? Color.green : Color.secondary)
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store = SettingsStore()
    var onSave: ((Configuration) -> String?)? { didSet { store.onSave = onSave } }
    var onPermission: (() -> Void)? { didSet { store.onPermission = onPermission } }
    var onEnableShortcut: (() -> Void)? { didSet { store.onEnableShortcut = onEnableShortcut } }
    var onShortcutRecording: ((Bool) -> Void)? { didSet { store.onShortcutRecording = onShortcutRecording } }

    func show(_ configuration: Configuration) {
        prepare(configuration)
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    private func prepare(_ configuration: Configuration) {
        store.configuration = configuration; store.error = nil; store.refreshPermissions()
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Whisper Settings"; window.isReleasedWhenClosed = false
            window.contentView = host; window.delegate = self; window.center()
            self.window = window
        }
    }
    func setShortcutStatus(ready: Bool) {
        store.shortcutReady = ready
        store.refreshPermissions()
    }
    func setBusy(_ busy: Bool) {
        store.isBusy = busy
        if busy { stopRecording(in: window?.contentView) }
    }
    func windowWillClose(_ notification: Notification) { stopRecording(in: window?.contentView) }
    private func stopRecording(in view: NSView?) {
        guard let view else { return }
        if let recorder = view as? ShortcutRecorderButton { recorder.finish() }
        for child in view.subviews { stopRecording(in: child) }
    }
    static func verifyShortcutRecorder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        let button = ShortcutRecorderButton(frame: NSRect(x: 10, y: 10, width: 200, height: 28))
        window.contentView?.addSubview(button)
        var states: [Bool] = []; var captured: [(UInt16, UInt64)] = []
        button.onRecordingChanged = { states.append($0) }
        button.onCapture = { captured.append(($0, $1)) }
        guard !button.accept(key: 2, modifiers: 0x80000) else { throw AppFailure("Recorder armed without a click.") }
        button.performClick(nil)
        _ = button.accept(key: 2, modifiers: 0) // Bare letters must not save.
        _ = button.accept(key: 2, modifiers: 0x80000, isRepeat: true)
        guard captured.isEmpty else { throw AppFailure("Invalid or repeated shortcut saved.") }
        _ = button.accept(key: 2, modifiers: 0x80000)
        guard captured.count == 1, captured[0].0 == 2, captured[0].1 == 0x80000,
              states == [true, false] else { throw AppFailure("Option+D capture failed.") }
        button.performClick(nil); _ = button.accept(key: 53, modifiers: 0)
        guard captured.count == 1, states == [true, false, true, false] else {
            throw AppFailure("Escape cancellation failed.")
        }
        button.performClick(nil); button.finish()
        guard states == [true, false, true, false, true, false],
              !button.accept(key: 5, modifiers: 0x100000) else {
            throw AppFailure("Recorder teardown failed.")
        }
        // No synthetic events posted, no global tap installed, no microphone requested.
    }
    // First-party offscreen preview: no microphone, event tap or screen recording.
    func renderPreview(to url: URL) throws {
        prepare(Configuration())
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AppFailure("Settings preview unavailable.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}
