import Foundation
import Testing

@testable import OurWhisper

@Suite("History")
@MainActor
struct HistoryStoreTests {
    private func entry(
        daysAgo: Double = 0,
        text: String = "hello world",
        app: String? = "Slack",
        bundle: String? = "com.tinyspeck.slackmacgap",
        audio: TimeInterval = 4,
        processing: TimeInterval = 0.4
    ) -> HistoryEntry {
        HistoryEntry(
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            rawText: text,
            finalText: text,
            appName: app,
            appBundleID: bundle,
            modeName: "General",
            providerID: .parakeet,
            language: .english,
            usedModel: false,
            audioDuration: audio,
            processingTime: processing
        )
    }

    @Test("Newest first")
    func insertsNewestFirst() {
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        store.record(entry(text: "first"), settings: HistorySettings())
        store.record(entry(text: "second"), settings: HistorySettings())

        #expect(store.entries.first?.finalText == "second")
    }

    @Test("Nothing is recorded when history is off")
    func respectsTheOffSwitch() {
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        var settings = HistorySettings()
        settings.isEnabled = false
        store.record(entry(), settings: settings)

        #expect(store.entries.isEmpty)
    }

    @Test("Retention actually deletes")
    func enforcesRetention() {
        // A retention setting that only claims to delete is worse than none at all, because the
        // user believes their transcripts are gone.
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        store.record(entry(daysAgo: 40, text: "old"), settings: HistorySettings())
        store.record(entry(daysAgo: 1, text: "recent"), settings: HistorySettings())
        store.prune(retention: .days30)

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.finalText == "recent")
    }

    @Test("Keep-forever prunes nothing")
    func keepsForever() {
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        var settings = HistorySettings()
        settings.retention = .forever
        store.record(entry(daysAgo: 4_000, text: "ancient"), settings: settings)
        store.prune(retention: .forever)

        #expect(store.entries.count == 1)
    }

    @Test("Search covers the cleaned text, the raw text and the app")
    func searches() {
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        var mixed = entry(text: "final wording")
        mixed.rawText = "um final wording"
        store.record(mixed, settings: HistorySettings())

        #expect(store.search("final").count == 1)
        #expect(store.search("um").count == 1)
        #expect(store.search("Slack").count == 1)
        #expect(store.search("nothing here").isEmpty)
        #expect(store.search("   ").count == 1)  // a blank query means "everything"
    }

    @Test("Stats count words, apps and time saved")
    func computesStats() {
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        store.record(entry(text: "one two three", bundle: "com.apple.mail"), settings: HistorySettings())
        store.record(entry(text: "four five", bundle: "com.tinyspeck.slackmacgap"), settings: HistorySettings())

        let stats = store.stats
        #expect(stats.totalWords == 5)
        #expect(stats.distinctApps == 2)
        #expect(stats.averageRealtimeFactor > 0)
    }

    @Test("Time saved is never negative")
    func neverReportsNegativeSavings() {
        // A one-word dictation takes longer than typing it. The headline stat must floor at zero
        // rather than claim the app cost you time.
        let temp = TemporaryDirectory()
        let store = HistoryStore(directory: temp.url)

        store.record(entry(text: "hi", audio: 30, processing: 10), settings: HistorySettings())
        #expect(store.stats.secondsSaved == 0)
    }

    @Test("Entries survive a reload")
    func persists() {
        let temp = TemporaryDirectory()

        let first = HistoryStore(directory: temp.url)
        first.record(entry(text: "persisted"), settings: HistorySettings())
        first.flush()

        let second = HistoryStore(directory: temp.url)
        #expect(second.entries.first?.finalText == "persisted")
    }
}

@Suite("Modes")
@MainActor
struct ModeStoreTests {
    @Test("A fresh install gets the built-in modes")
    func seedsBuiltIns() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        #expect(store.modes.count == Mode.builtIns.count)
    }

    @Test("The app you are typing into wins over the saved selection")
    func resolvesByApp() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)

        var settings = RefinementSettings()
        settings.autoSwitchByApp = true
        settings.activeModeID = store.modes.first?.id

        let resolved = store.resolve(settings: settings, frontmostBundleID: "com.microsoft.VSCode")
        #expect(resolved.name == "Code")
    }

    @Test("With auto-switch off, the saved selection wins")
    func respectsManualSelection() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let email = try! #require(store.modes.first { $0.name == "Email" })

        var settings = RefinementSettings()
        settings.autoSwitchByApp = false
        settings.activeModeID = email.id

        let resolved = store.resolve(settings: settings, frontmostBundleID: "com.microsoft.VSCode")
        #expect(resolved.id == email.id)
    }

    @Test("An unclaimed app falls back to the selection")
    func fallsBackWhenNoAppMatches() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let email = try! #require(store.modes.first { $0.name == "Email" })

        var settings = RefinementSettings()
        settings.autoSwitchByApp = true
        settings.activeModeID = email.id

        let resolved = store.resolve(settings: settings, frontmostBundleID: "com.example.unknown")
        #expect(resolved.id == email.id)
    }

    @Test("Resolving always returns something")
    func alwaysResolves() {
        // A dictation must never fail for want of a mode, including when the saved id points at a
        // mode that has since been deleted.
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)

        var settings = RefinementSettings()
        settings.activeModeID = UUID()

        _ = store.resolve(settings: settings, frontmostBundleID: nil)
    }

    @Test("The clipboard is only read when some mode asks for it")
    func reportsWhetherAnyModeWantsTheClipboard() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        #expect(store.anyModeReadsClipboard == false)  // nothing ships with either toggle on

        var code = store.modes.first { $0.name == "Code" }!
        code.usesClipboardContext = true
        store.update(code)
        #expect(store.anyModeReadsClipboard)
    }

    @Test("Pasting the clipboard is reason enough to read it")
    func readsTheClipboardForPastingToo() {
        // Two independent toggles, one read. Either being on anywhere has to be enough, or the
        // paste toggle would silently do nothing for anyone who left the context one off.
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)

        var general = store.modes.first { $0.name == "General" }!
        general.pastesClipboard = true
        store.update(general)

        #expect(store.anyModeReadsClipboard)
    }

    @Test("Built-in modes cannot be deleted")
    func protectsBuiltIns() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = store.modes.count

        store.delete(store.modes[0].id)
        #expect(store.modes.count == before)
    }

    @Test("A custom mode can be added and deleted")
    func addsAndDeletesCustomModes() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = store.modes.count

        let added = store.add(name: "Meeting notes")
        #expect(store.modes.count == before + 1)

        store.delete(added.id)
        #expect(store.modes.count == before)
    }

    @Test("Resetting a built-in restores what shipped")
    func resetsBuiltIns() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)

        var edited = store.modes[0]
        let original = edited.name
        edited.name = "Mangled"
        store.update(edited)
        #expect(store.modes[0].name == "Mangled")

        store.resetToShipped(edited.id)
        #expect(store.modes[0].name == original)
    }

    @Test("A mode added in a later version appears for existing users")
    func mergesNewBuiltIns() {
        // Someone who installed when there were three built-in modes should get the fourth on
        // upgrade, without losing their edits to the first three.
        let temp = TemporaryDirectory()
        let file = JSONFileStore<[Mode]>(fileName: "modes.json", directory: temp.url)
        var partial = Array(Mode.builtIns.prefix(2))
        partial[0].name = "My edited mode"
        file.save(partial)
        file.flush()

        let store = ModeStore(directory: temp.url)
        #expect(store.modes.count == Mode.builtIns.count)
        #expect(store.modes[0].name == "My edited mode")
    }
}

@Suite("Settings")
@MainActor
struct SettingsStoreTests {
    @Test("Settings survive a reload")
    func persists() {
        let temp = TemporaryDirectory()

        let first = SettingsStore(directory: temp.url)
        first.settings.dictation.language = .ukrainian
        first.settings.sound.playFeedbackSounds = false
        first.flush()

        let second = SettingsStore(directory: temp.url)
        #expect(second.settings.dictation.language == .ukrainian)
        #expect(second.settings.sound.playFeedbackSounds == false)
    }

    @Test("A file from an older version loads, with defaults for what is missing")
    func toleratesAnOlderFile() throws {
        // Every field has a default precisely so this works. Without it, adding a setting would
        // wipe everyone's configuration on upgrade.
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"dictation":{"language":"uk"}}"#.utf8).write(to: url)

        let store = SettingsStore(directory: temp.url)
        #expect(store.settings.dictation.language == .ukrainian)
        #expect(store.settings.history.retention == .days30)
    }

    @Test("A settings file written for Apple's model does not keep Gemma off")
    func theOldCleanupSwitchIsNotReadAsTheNewOne() throws {
        // Every file the app has written carries `useOnDeviceModel: false`: it switched Apple's
        // model, and it was off by default because most Macs could not run it. Read as the new
        // switch it would leave everyone who upgrades without the cleanup model, for a choice they
        // never made about this one.
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"refinement":{"isEnabled":true,"useOnDeviceModel":false}}"#.utf8).write(to: url)

        let store = SettingsStore(directory: temp.url)
        #expect(store.settings.refinement.useCleanupModel)
        #expect(store.settings.refinement.wantsCleanupModel)
    }

    @Test("Switching the cleanup model off is remembered", arguments: [
        (isEnabled: true, useCleanupModel: true, wants: true),
        (isEnabled: true, useCleanupModel: false, wants: false),
        // The master switch turns the model off as surely as its own does.
        (isEnabled: false, useCleanupModel: true, wants: false),
        (isEnabled: false, useCleanupModel: false, wants: false),
    ])
    func rememberstheCleanupSwitch(isEnabled: Bool, useCleanupModel: Bool, wants: Bool) {
        let temp = TemporaryDirectory()

        let first = SettingsStore(directory: temp.url)
        first.settings.refinement.isEnabled = isEnabled
        first.settings.refinement.useCleanupModel = useCleanupModel
        first.flush()

        let second = SettingsStore(directory: temp.url)
        #expect(second.settings.refinement.useCleanupModel == useCleanupModel)
        #expect(second.settings.refinement.wantsCleanupModel == wants)
    }

    @Test("An unreadable file is set aside, not deleted, and defaults are used")
    func quarantinesCorruptFiles() throws {
        let temp = TemporaryDirectory()
        let url = temp.url.appendingPathComponent("settings.json")
        try Data("{ this is not json".utf8).write(to: url)

        let store = SettingsStore(directory: temp.url)
        #expect(store.settings == Settings())
        // The original is kept so a hand-edited file that broke can still be recovered.
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }

    @Test("Reset restores defaults")
    func resets() {
        let temp = TemporaryDirectory()
        let store = SettingsStore(directory: temp.url)

        store.settings.dictation.language = .japanese
        store.resetToDefaults()

        #expect(store.settings == Settings())
    }

    @Test("A settings round trip is lossless")
    func roundTrips() throws {
        var settings = Settings()
        settings.dictation.language = .polish
        settings.dictation.pushToTalkChord = HotkeyChord(keyCode: 49, modifiers: [.maskCommand])
        settings.refinement.activeModeID = UUID()
        settings.history.retention = .days90
        settings.appearance.accent = .purple

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == settings)
    }
}

@Suite("Vocabulary")
@MainActor
struct VocabularyStoreTests {
    @Test("Only usable entries are handed to the refiner")
    func filtersUnusableEntries() {
        let temp = TemporaryDirectory()
        let store = VocabularyStore(directory: temp.url)

        store.add(term: "Kruhlov", soundsLike: ["Kruglov"])
        store.add(term: "", soundsLike: ["something"])          // no term to insert
        store.add(term: "Orphan", soundsLike: [])               // nothing to match
        var disabled = store.add(term: "Off", soundsLike: ["off"])
        disabled.isEnabled = false
        store.update(disabled)

        #expect(store.enabledEntries.count == 1)
        #expect(store.enabledEntries.first?.term == "Kruhlov")
    }

    @Test("Longer spellings are matched first")
    func ordersPatternsLongestFirst() {
        // With "AI" and "AI agent" both listed, matching the short one first would consume the
        // word and leave the longer spelling unreachable.
        let entry = VocabularyEntry(term: "x", soundsLike: ["AI", "AI agent"])
        #expect(entry.patterns == ["AI agent", "AI"])
    }
}

@Suite("Data directory safety")
struct AppDirectoriesTests {
    /// The unit tests run inside the app, so `AppState()` and every store built without an
    /// explicit directory is constructed for real on every test run. This redirect is what stops
    /// that from reading and destroying the settings, modes, vocabulary and history of whoever
    /// runs the suite — a mistake that is silent, permanent, and easy to make.
    @Test("Under test, the support directory is never the real one")
    func redirectsAwayFromRealUserData() {
        #expect(AppDirectories.isRunningTests)

        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OurWhisper", isDirectory: true)

        #expect(AppDirectories.support.standardizedFileURL != real.standardizedFileURL)
        #expect(AppDirectories.support.path.contains("OurWhisper-test-host-"))
    }
}
