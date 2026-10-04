import ServiceManagement
import SwiftUI

/// Everything that is not a mode, a word, a sound or a transcript.
struct ConfigurationView: View {
    @Environment(AppState.self) private var appState

    @State private var apiKeyField = ""
    @State private var keySaved = false
    /// Read once and kept, because a Keychain lookup is an XPC call and this is asked for by four
    /// different parts of one row — on every render of the screen.
    @State private var hasKey = false

    var body: some View {
        @Bindable var settings = appState.settings

        SettingsPage {
            SettingsSection(title: "Dictation") {
                SettingsRow(
                    symbol: "globe",
                    title: "Language",
                    detail: languageDetail
                ) {
                    Picker("Language", selection: $settings.settings.dictation.language) {
                        ForEach(SpeechLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .frame(width: 190)
                }
                RowDivider()
                SettingsRow(
                    symbol: "cpu",
                    title: "Engine",
                    detail: "Offline runs on this Mac. Cloud sends audio to Soniox with your key."
                ) {
                    Picker("Engine", selection: $settings.settings.dictation.provider) {
                        Text("Parakeet (offline)").tag(TranscriptionProviderID.parakeet)
                        Text("Soniox (cloud)").tag(TranscriptionProviderID.soniox)
                    }
                    .frame(width: 190)
                }
                RowDivider()
                SettingsRow(
                    symbol: "arrow.triangle.branch",
                    title: "Use the cloud model for languages Parakeet cannot handle",
                    detail: "Off means Chinese and Japanese fail with an explanation instead of uploading your audio. Audio never leaves this Mac unless this is on."
                ) {
                    Toggle("", isOn: $settings.settings.dictation.allowCloudFallback)
                        .toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(
                    symbol: "doc.on.clipboard",
                    title: "Keep the text on the clipboard when there is nowhere to paste it",
                    detail: "Dictating with no text field focused otherwise loses what you said — the paste goes nowhere and your previous clipboard is put back over it. On, the transcript stays on the clipboard and the pill says so; what you had copied before is not restored."
                ) {
                    Toggle("", isOn: $settings.settings.dictation.keepOnClipboardWhenNothingFocused)
                        .toggleStyle(.switch)
                }
            }

            SettingsSection(title: "Hotkey") {
                SettingsRow(
                    symbol: "hand.tap",
                    title: "How the hotkey behaves",
                    detail: "Toggle: press to start, press again to stop. Hold: record only while held."
                ) {
                    Picker("Mode", selection: $settings.settings.dictation.hotkeyMode) {
                        Text("Press to toggle").tag(HotkeyMode.toggle)
                        Text("Hold to talk").tag(HotkeyMode.pushToTalk)
                    }
                    .frame(width: 190)
                }
                RowDivider()
                HotkeyRecorderRow(
                    title: "Shortcut",
                    detail: "Modifier-only combinations are allowed, and are the point — ⌥⌘⌃⇧ collides with nothing.",
                    chord: $settings.settings.dictation.toggleChord
                )
                RowDivider()
                HotkeyRecorderRow(
                    title: "Hold-to-talk key",
                    detail: "Held down, records; released, stops. fn is the default — it is under your thumb and no app uses it. Works alongside the shortcut above.",
                    chord: pushToTalkBinding,
                    allowsSingleModifier: true,
                    onClear: { settings.settings.dictation.pushToTalkChord = nil }
                )
                RowDivider()
                SettingsRow(
                    symbol: "timer",
                    title: "Wait before hold-to-talk starts",
                    detail: "macOS claims a tap of fn for switching language and the emoji picker. A wait lets a tap go to macOS and a hold come to us. Only applies to a single modifier; a key combination always starts at once."
                ) {
                    Picker("Delay", selection: $settings.settings.dictation.pushToTalkHoldDelay) {
                        Text("Start at once").tag(0.0)
                        Text("0.5 seconds").tag(0.5)
                        Text("1 second").tag(1.0)
                        Text("1.5 seconds").tag(1.5)
                        Text("2 seconds").tag(2.0)
                    }
                    .frame(width: 190)
                }
                RowDivider()
                SettingsRow(
                    symbol: "escape",
                    title: "Cancel a recording",
                    detail: "Escape, while recording. The audio is discarded and nothing is pasted."
                ) {
                    KeycapRow(glyphs: ["esc"])
                }
            }

            SettingsSection(
                title: "Cleanup",
                subtitle: "What happens to the transcript between the speech model and your text field."
            ) {
                SettingsRow(
                    symbol: "wand.and.stars",
                    title: "Clean up transcripts",
                    detail: "Off pastes exactly what the speech model produced, filler and all."
                ) {
                    Toggle("", isOn: $settings.settings.refinement.isEnabled).toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(
                    symbol: "sparkles",
                    title: "Clean up with Gemma 4",
                    detail: appState.onDeviceRefiner.availability.explanation
                ) {
                    // Never disabled: this switch is what downloads and loads the model, so a
                    // missing model is a reason to turn it on rather than a reason it cannot be.
                    Toggle("", isOn: $settings.settings.refinement.useCleanupModel)
                        .toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(
                    symbol: "app.badge",
                    title: "Switch modes by app",
                    detail: "Pick the mode that claims the app you are typing into."
                ) {
                    Toggle("", isOn: $settings.settings.refinement.autoSwitchByApp).toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(
                    symbol: "list.bullet",
                    title: "Mode",
                    detail: "Used when no mode claims the focused app. An assistant mode is never claimed by an app, so this and the menu bar are where one is chosen."
                ) {
                    Picker("Mode", selection: $settings.settings.refinement.activeModeID) {
                        ForEach(appState.modes.modes) { mode in
                            Text(mode.name).tag(Optional(mode.id))
                        }
                    }
                    .frame(width: 190)
                }
            }

            SettingsSection(
                title: "Soniox API key",
                subtitle: "Stored in the macOS Keychain, never in a file or a log, and only ever sent to Soniox."
            ) {
                SettingsRow(
                    symbol: hasKey ? "key.fill" : "key",
                    title: hasKey ? "A key is saved" : "No key saved",
                    detail: "Get one at soniox.com. The app works fully without it — the key only unlocks the cloud languages.",
                    tint: hasKey ? .green : .secondary
                ) {
                    HStack(spacing: 8) {
                        SecureField("sk-…", text: $apiKeyField)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button(keySaved ? "Saved" : "Save") {
                            KeychainStore.write(apiKeyField, for: .soniox)
                            apiKeyField = ""
                            keySaved = true
                            hasKey = KeychainStore.has(.soniox)
                            appState.models.refresh()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyField.isEmpty)
                    }
                }
                RowDivider()
                SettingsRow(
                    symbol: "trash",
                    title: "Remove the saved key",
                    detail: "Deletes it from the Keychain. The cloud languages stop working until a new key is added."
                ) {
                    Button("Remove") {
                        KeychainStore.delete(.soniox)
                        keySaved = false
                        hasKey = false
                        appState.models.refresh()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey)
                }
            }

            StartupSection()

            SettingsSection(title: "Appearance") {
                SettingsRow(symbol: "circle.lefthalf.filled", title: "Theme") {
                    Picker("Theme", selection: $settings.settings.appearance.theme) {
                        ForEach(Theme.allCases) { theme in
                            Label(theme.title, systemImage: theme.symbol).tag(theme)
                        }
                    }
                    .frame(width: 150)
                }
                RowDivider()
                SettingsRow(symbol: "paintpalette", title: "Accent colour") {
                    Picker("Accent", selection: $settings.settings.appearance.accent) {
                        ForEach(AccentTint.allCases) { tint in
                            Text(tint.title).tag(tint)
                        }
                    }
                    .frame(width: 150)
                }
                RowDivider()
                SettingsRow(
                    symbol: "capsule",
                    title: "Show the recording pill",
                    detail: "Off leaves only the menu bar icon to show that recording is live."
                ) {
                    Toggle("", isOn: $settings.settings.appearance.showPill).toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(
                    symbol: "rectangle.and.hand.point.up.left",
                    title: "Pill style",
                    detail: "Small is the capsule with the level bars. With modes, the capsule opens into a larger window while you speak, with every mode in it — click one to use it for this dictation only."
                ) {
                    Picker("Pill style", selection: $settings.settings.appearance.pillStyle) {
                        ForEach(PillStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .disabled(!settings.settings.appearance.showPill)
                }
                RowDivider()
                SettingsRow(
                    symbol: "dock.rectangle",
                    title: "Show in the Dock",
                    detail: "OurWhisper is a menu bar app, so by default it has no Dock icon and does not appear in command-tab. Turn this on if you would rather find it the ordinary way."
                ) {
                    Toggle("", isOn: $settings.settings.appearance.showInDock).toggleStyle(.switch)
                }
            }

            UpdatesSection()

            SettingsSection(title: "Reset") {
                SettingsRow(
                    symbol: "arrow.counterclockwise",
                    title: "Reset settings to defaults",
                    detail: "Leaves your modes, vocabulary, history, API key and downloaded models alone. Each of those has its own delete button."
                ) {
                    Button("Reset") { appState.settings.resetToDefaults() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .onAppear { hasKey = KeychainStore.has(.soniox) }
        .onChange(of: appState.settings.settings.appearance.theme) { _, theme in
            theme.apply()
        }
        .onChange(of: appState.settings.settings.dictation) { _, _ in
            appState.dictation.applySettings()
        }
        .onChange(of: appState.settings.settings.appearance.showInDock) { _, showInDock in
            WindowPresenter.setShowsDockIcon(showInDock)
        }
        // Here and not on the switch: Reset can turn it back on too, and the Updates section is
        // in a lazy stack, so it may not exist yet when that happens. Switching *on* asks now,
        // because the loop in `AppState.watchForUpdates` would otherwise take up to a day.
        .onChange(of: appState.settings.settings.updates.checkAutomatically) { _, isOn in
            guard isOn, appState.availableUpdate == nil else { return }
            Task { await appState.checkForUpdate() }
        }
        .onChange(of: appState.settings.settings.refinement.wantsCleanupModel) { _, wanted in
            // Off frees the 2.8 GB the model holds in memory and keeps the file, so turning it
            // back on is a load of a second or two rather than another download.
            Task {
                if wanted {
                    await appState.onDeviceRefiner.prepare()
                } else {
                    await appState.onDeviceRefiner.unload()
                }
            }
        }
    }

    /// The stored chord is optional — "no hold-to-talk key" is a real state. The recorder wants a
    /// non-optional binding, so an unbound chord reads as empty and writing an empty one clears it.
    private var pushToTalkBinding: Binding<HotkeyChord> {
        Binding(
            get: { appState.settings.settings.dictation.pushToTalkChord ?? HotkeyChord(modifiers: []) },
            set: { appState.settings.settings.dictation.pushToTalkChord = $0.isEmpty ? nil : $0 }
        )
    }

    private var languageDetail: String {
        let language = appState.settings.settings.dictation.language
        if language.isLocal {
            return "Handled offline by Parakeet."
        }
        return appState.settings.settings.dictation.allowCloudFallback
            ? "Not covered offline — this language goes to Soniox."
            : "Not covered offline. Turn on the cloud switch below, or this language will refuse to transcribe."
    }
}

// MARK: - Startup

/// The login-item toggle.
///
/// Holds its own `@State` because the truth lives in `SMAppService`, not in `Settings`, and a
/// plain computed binding would leave the switch showing the old value after a failed register.
/// Re-read on appear so a change made in System Settings shows up here.
private struct StartupSection: View {
    @State private var isEnabled = false
    /// Starts at a placeholder and is filled in on appear. A `@State` default is an ordinary
    /// expression: it is evaluated every time this struct is built — which is every time anything
    /// on the Configuration screen changes — even though SwiftUI keeps only the first result. With
    /// `LaunchAtLogin.status` there, flipping any switch on the screen cost an XPC round trip to
    /// the background task daemon.
    @State private var status: SMAppService.Status = .notRegistered
    /// Why the last attempt did not take. Nil until something actually fails.
    @State private var failure: String?

    var body: some View {
        SettingsSection(title: "Startup") {
            SettingsRow(
                symbol: "power",
                title: "Open at login",
                // From the state, not a fresh read: `LaunchAtLogin.status` is an XPC call and a
                // detail string is rebuilt every time anything on this screen changes.
                detail: failure ?? LaunchAtLogin.explanation(for: status),
                tint: isEnabled ? .green : .secondary
            ) {
                HStack(spacing: 8) {
                    if status == .requiresApproval {
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                            .buttonStyle(.bordered)
                    }
                    // Only an approval macOS refuses to override from code disables the switch.
                    // `.notFound` does not: an app that has never registered reports it too, and
                    // registering from that state is exactly what this switch is for.
                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .disabled(status == .requiresApproval)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: isEnabled) { _, wanted in
            // A refused registration must not leave the switch showing a state macOS disagrees
            // with, so the answer always comes back from the system.
            failure = LaunchAtLogin.set(wanted)
            refresh()
        }
    }

    private func refresh() {
        status = LaunchAtLogin.status
        let enabled = LaunchAtLogin.isEnabled
        // Guarded, or writing the value we just read would re-enter `onChange` and register again.
        if isEnabled != enabled { isEnabled = enabled }
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    @Environment(AppState.self) private var appState

    /// Read once, not from `body` — see `UpdateActions`.
    @State private var refusal: String?

    var body: some View {
        @Bindable var settings = appState.settings

        SettingsSection(
            title: "Updates",
            subtitle: "The only requests the app makes on its own, and unauthenticated reads of a public page — nothing about you or this Mac is sent. Checking happens by itself if you let it — when the app starts, then again once a day; downloading only ever happens when you press the button."
        ) {
            SettingsRow(
                symbol: "arrow.down.circle",
                title: "Check for updates automatically",
                detail: statusDetail
            ) {
                Toggle("", isOn: $settings.settings.updates.checkAutomatically).toggleStyle(.switch)
            }
            RowDivider()
            // The same offer as the Home screen's banner, in the place the Check button leads to.
            // Finding out a release exists and having nothing to press is where this screen used
            // to end.
            if case .available(let release) = appState.updates.state {
                SettingsRow(
                    symbol: UpdateActions.isWarning(phase: appState.installer.phase, refusal: refusal)
                        ? "exclamationmark.triangle.fill"
                        : "arrow.down.circle.fill",
                    title: "Version \(release.version) is available",
                    detail: UpdateActions.detail(
                        phase: appState.installer.phase,
                        refusal: refusal,
                        release: release
                    ),
                    tint: UpdateActions.isWarning(phase: appState.installer.phase, refusal: refusal)
                        ? .orange
                        : .accentColor
                ) {
                    UpdateActions(release: release, phase: appState.installer.phase, refusal: refusal)
                }
            } else {
                SettingsRow(
                    symbol: "magnifyingglass",
                    title: "Check now",
                    detail: "Version \(UpdateChecker.currentVersion)"
                ) {
                    Button("Check") {
                        Task { await appState.checkForUpdate(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.updates.state == .checking)
                }
            }
        }
        .task { refusal = appState.installer.refusal }
    }

    private var statusDetail: String {
        switch appState.updates.state {
        case .idle:
            "Not checked yet this session."
        case .checking:
            "Checking…"
        case .upToDate(let date):
            "Up to date, checked \(date.formatted(date: .abbreviated, time: .shortened))."
        case .available(let release):
            "Version \(release.version) is available."
        case .failed(let message):
            message
        }
    }
}

// MARK: - Hotkey recorder

/// Captures the next chord the user presses.
///
/// A plain shortcut control cannot express this: the app's default binding is four modifiers and
/// no key, and the push-to-talk default is fn alone. Neither is a shortcut AppKit will record.
///
/// The interaction that matters is **commit on release**. You press the combination, let go, and
/// it is saved — the same as every other shortcut recorder on the platform. Committing on the way
/// *down* would save a half-pressed chord, since holding ⌥⌘⌃⇧ arrives as four separate events.
struct HotkeyRecorderRow: View {
    let title: String
    let detail: String
    @Binding var chord: HotkeyChord
    /// Push-to-talk wants a single modifier (fn); the toggle chord wants at least two so a stray
    /// ⇧ on the way to the real combination is not recorded as the shortcut.
    var allowsSingleModifier: Bool = false
    var onClear: (() -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// The largest set of modifiers seen during this recording. Held down is a sequence of
    /// events; this is what the user actually pressed.
    @State private var candidate: CGEventFlags = []

    var body: some View {
        SettingsRow(
            symbol: "keyboard",
            title: title,
            detail: isRecording ? "Press the keys, then let go. Escape cancels." : detail
        ) {
            HStack(spacing: 8) {
                if isRecording, !candidate.isEmpty {
                    KeycapRow(glyphs: HotkeyChord(modifiers: candidate).displayGlyphs)
                } else if !chord.isEmpty {
                    KeycapRow(glyphs: chord.displayGlyphs)
                } else {
                    Text("None").font(.system(size: 12)).foregroundStyle(.secondary)
                }

                Button(isRecording ? "Listening…" : "Change") {
                    isRecording ? cancel() : record()
                }
                .buttonStyle(.bordered)

                if let onClear, !chord.isEmpty, !isRecording {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Unbind this shortcut")
                }
            }
        }
        .onDisappear { cancel() }
    }

    private func record() {
        isRecording = true
        candidate = []

        // A local monitor, not a global one: this window has focus while recording a shortcut, and
        // a global tap would need the same Accessibility permission for no extra benefit.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard isRecording else { return event }

            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                .intersection(HotkeyChord.significantFlags)

            if event.type == .keyDown {
                if event.keyCode == 53 { cancel(); return nil }  // escape
                chord = HotkeyChord(keyCode: CGKeyCode(event.keyCode), modifiers: flags)
                finish()
                return nil
            }

            // Still going down: remember the widest combination reached so far.
            if flags.rawValue > candidate.rawValue || flags.isSuperset(of: candidate) {
                candidate = flags
                return nil
            }

            // Coming back up. The moment the first key is released, what was held is the answer.
            if !candidate.isEmpty, !flags.isSuperset(of: candidate) {
                if allowsSingleModifier || candidate.hasAtLeastTwoModifiers {
                    chord = HotkeyChord(modifiers: candidate)
                    finish()
                } else {
                    // Too few keys to be a safe global shortcut. Start over rather than binding
                    // something that would fire constantly.
                    candidate = []
                }
                return nil
            }

            return nil
        }
    }

    private func finish() {
        isRecording = false
        candidate = []
        removeMonitor()
    }

    private func cancel() {
        isRecording = false
        candidate = []
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private extension CGEventFlags {
    var isEmpty: Bool { rawValue == 0 }

    /// Two or more bits set. A single modifier held for a fraction of a second is something people
    /// do by accident all day; two is deliberate.
    var hasAtLeastTwoModifiers: Bool {
        rawValue != 0 && rawValue & (rawValue - 1) != 0
    }
}
