import AppKit
import SwiftUI
import Testing

@testable import OurWhisper

/// Builds every screen and forces a layout pass.
///
/// A SwiftUI view that crashes on construction — a force-unwrapped binding, a `Picker` whose
/// selection type does not match its tags, an index out of range in a list — compiles perfectly
/// and fails the first time a person clicks that sidebar row. Unit tests over the stores do not
/// catch it, because none of them ever build a view.
///
/// This is deliberately shallow: it proves each screen can be constructed and laid out against
/// real stores, not that it looks right. Looking right is still a human's job.
///
/// Serialized: these build AppKit windows, and running several at once churns the shared
/// application state in ways that have nothing to do with the views under test.
@Suite("Screens render", .serialized)
@MainActor
struct ViewRenderingTests {
    /// Stores pointed at a temporary directory, so rendering a screen cannot read or write the
    /// real settings, modes, vocabulary or history of whoever runs the suite.
    private func makeState() -> (AppState, TemporaryDirectory) {
        let temp = TemporaryDirectory()
        let state = AppState(directory: temp.url)
        return (state, temp)
    }

    private func render(_ view: some View, size: CGSize = CGSize(width: 900, height: 700)) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        // Without a window the view is never attached to a display list and SwiftUI skips most of
        // the work, which would make this test pass on views that crash in practice.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on `close()`. ARC then releases it
        // again, which crashes the whole test process rather than failing one test.
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        window.orderOut(nil)
        window.contentView = nil
    }

    @Test("Every sidebar destination builds and lays out", arguments: NavigationSection.allCases)
    func rendersEverySection(section: NavigationSection) {
        let (state, temp) = makeState()
        state.selectedSection = section
        render(RootView().environment(state))
        _ = temp
    }

    @Test("The update controls build in every phase they can be in", arguments: [
        UpdateInstaller.Phase.idle,
        .downloading(0.42),
        .downloading(nil),
        .verifying,
        .installing,
        .restarting,
        .installedNeedsRestart,
        .failed("The download does not match its published checksum."),
    ])
    func rendersUpdateControls(phase: UpdateInstaller.Phase) {
        // The banner swaps its controls out per phase — buttons, a bar, a spinner — and a `switch`
        // in a `ViewBuilder` is exactly the shape that compiles and then crashes on one branch.
        let (state, temp) = makeState()
        render(UpdateActions(release: Self.release, phase: phase, refusal: nil).environment(state))
        // And the same phase dressed as a refusal, which swaps the symbol and the tint.
        render(UpdateActions(release: Self.release, phase: phase, refusal: "Ad-hoc signed.").environment(state))
        _ = temp
    }

    @Test("The menu's update item builds in every phase it can be in", arguments: [
        UpdateInstaller.Phase.idle,
        .downloading(0.42),
        .downloading(nil),
        .verifying,
        .installing,
        .restarting,
        .installedNeedsRestart,
        .failed("The download does not match its published checksum."),
    ])
    func rendersUpdateMenuItem(phase: UpdateInstaller.Phase) {
        let (state, temp) = makeState()
        render(UpdateMenuItem(release: Self.release, phase: phase, refusal: nil, openHome: {}).environment(state))
        render(UpdateMenuItem(release: Self.release, phase: phase, refusal: "Ad-hoc signed.", openHome: {}).environment(state))
        _ = temp
    }

    @Test("The update banner builds against a real AppState")
    func rendersUpdateBanner() {
        let (state, temp) = makeState()
        render(UpdateBanner(release: Self.release).environment(state))
        _ = temp
    }

    private static let release = UpdateChecker.Release(
        version: "9.9.9",
        title: "Nine",
        notes: "",
        url: URL(string: "https://github.com/grozoww/our-whisper/releases/tag/v9.9.9")!,
        publishedAt: nil,
        dmg: UpdateChecker.Asset(
            name: "OurWhisper-9.9.9-unnotarized.dmg",
            url: URL(string: "https://example.invalid/OurWhisper-9.9.9-unnotarized.dmg")!,
            size: 1
        ),
        checksums: URL(string: "https://example.invalid/SHA256SUMS")!
    )

    @Test("The speech model row builds in every state it can be in", arguments: [
        SpeechModelStatus.State.notLoaded,
        .starting,
        .downloading(0.38),
        .optimizing,
        .ready,
        .failed("The Internet connection appears to be offline."),
    ])
    func rendersSpeechModelRow(status: SpeechModelStatus.State) {
        // The row swaps its control per state — a bar, a spinner with a clock, a button — and a
        // `switch` in a `ViewBuilder` compiles whichever branch is wrong.
        render(ModelRow(status: status, startedAt: .now, phase: .idle, provider: .parakeet, retry: {}), size: CGSize(width: 700, height: 120))
        render(ModelRow(status: status, startedAt: nil, phase: .failed("Nothing was said"), provider: .parakeet, retry: {}), size: CGSize(width: 700, height: 120))
        render(ModelRow(status: status, startedAt: nil, phase: .listening, provider: .soniox, retry: {}), size: CGSize(width: 700, height: 120))
    }

    @Test("Home and the Models screen build while the speech and cleanup models are mid-flight", arguments: [
        (SpeechModelStatus.State.downloading(0.38), OnDeviceRefiner.Availability.notDownloaded),
        (.optimizing, .downloading(0.4)),
        (.starting, .loading),
        (.failed("offline"), .failed("Gemma 4 could not be set up: offline It tries again at the next launch.")),
        (.ready, .available),
    ])
    func rendersScreensMidFlight(status: SpeechModelStatus.State, cleanup: OnDeviceRefiner.Availability) {
        let temp = TemporaryDirectory()
        let state = AppState(
            directory: temp.url,
            speechModel: SpeechModelStatus(state: status),
            cleanupModel: OnDeviceRefiner(directory: temp.url, availability: cleanup)
        )
        for section in [NavigationSection.home, .modelsLibrary, .configuration] {
            state.selectedSection = section
            render(RootView().environment(state))
        }
    }

    @Test("Home renders with history present")
    func rendersHomeWithData() {
        let (state, temp) = makeState()
        state.history.record(
            HistoryEntry(
                rawText: "um hello",
                finalText: "Hello.",
                appName: "Slack",
                appBundleID: "com.tinyspeck.slackmacgap",
                modeName: "Chat",
                providerID: .parakeet,
                language: .english,
                usedModel: false,
                audioDuration: 3,
                processingTime: 0.3
            ),
            settings: HistorySettings()
        )
        state.selectedSection = .home
        render(RootView().environment(state))
        _ = temp
    }

    @Test("History renders with an entry selected")
    func rendersHistoryDetail() {
        let (state, temp) = makeState()
        for index in 0..<3 {
            state.history.record(
                HistoryEntry(
                    rawText: "raw \(index)",
                    finalText: "final \(index)",
                    appName: "Mail",
                    appBundleID: "com.apple.mail",
                    modeName: "Email",
                    providerID: .soniox,
                    language: .ukrainian,
                    usedModel: true,
                    audioDuration: 5,
                    processingTime: 1,
                    audioFileName: "\(index).wav"
                ),
                settings: HistorySettings()
            )
        }
        state.selectedSection = .history
        render(RootView().environment(state))
        _ = temp
    }

    @Test("Vocabulary renders with entries")
    func rendersVocabularyWithEntries() {
        let (state, temp) = makeState()
        state.vocabulary.add(term: "Kruhlov", soundsLike: ["Kruglov"])
        state.selectedSection = .vocabulary
        render(RootView().environment(state))
        _ = temp
    }

    @Test("Modes renders each mode's editor", arguments: 0..<Mode.builtIns.count)
    func rendersEachModeEditor(index: Int) {
        let (state, temp) = makeState()
        state.settings.settings.refinement.activeModeID = state.modes.modes[index].id
        state.selectedSection = .modes
        render(RootView().environment(state))
        _ = temp
    }

    @Test("The icon picker builds with a catalogue icon, a custom one and a broken one", arguments: [
        "sparkles",
        "tortoise",
        "not.a.symbol.at.all",
        "",
    ])
    func rendersIconPicker(symbol: String) {
        // The popover is its own window, so rendering the editor does not build it. It has a
        // branch for each way the stored name can relate to the catalogue — on it, off it, or not
        // a symbol at all — and a hand-edited modes file can hold any of them.
        for tint in ModeColor.allCases {
            render(
                SymbolPickerPopover(symbol: .constant(symbol), tint: tint, dismiss: {}),
                size: CGSize(width: 330, height: 420)
            )
        }
        render(ModeIconButton(symbol: .constant(symbol), tint: .blue), size: CGSize(width: 120, height: 60))
        render(TintSwatches(tint: .constant(.purple)), size: CGSize(width: 300, height: 100))
    }

    @Test("The pill renders in every phase", arguments: [
        PillModel.Phase.listening,
        .transcribing,
        .formatting,
        .success("Slack"),
        .failure("Could not paste. The text is on your clipboard."),
    ])
    func rendersPillPhases(phase: PillModel.Phase) {
        let model = PillModel()
        model.phase = phase
        render(PillView().environment(model), size: CGSize(width: 400, height: 140))
    }

    /// The bug this guards against: the pill's window is sized to this view, and the window server
    /// clips to the window frame. When the view was exactly the size of the capsule, the drop
    /// shadow was cut off square and the pill appeared to sit inside a grey rectangle. The fix is
    /// transparent padding, and the only way to tell it is still there is to measure.
    @Test("The pill leaves room for its own shadow")
    func pillReservesShadowMargin() {
        let model = PillModel()
        let host = NSHostingView(rootView: PillView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let capsule = CGSize(width: 108, height: 44)
        let margin = PillView.shadowMargin
        #expect(host.fittingSize.height >= capsule.height + margin * 2)
        #expect(host.fittingSize.width >= capsule.width + margin * 2)
    }

    /// Why `PillWindowController.setPhase` has to re-fit the window rather than just assign the
    /// phase: a window sized to its content view does not resize when that content changes, so a
    /// phase that is wider than the one before it would be truncated and left off centre.
    @Test("Phases do not all want the same width")
    func pillPhasesDifferInWidth() {
        func width(of phase: PillModel.Phase) -> CGFloat {
            let model = PillModel()
            model.phase = phase
            let host = NSHostingView(rootView: PillView().environment(model))
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }

        let listening = width(of: .listening)
        #expect(width(of: .transcribing) > listening)
        #expect(width(of: .failure("Could not paste. The text is on your clipboard.")) > listening)
    }

    /// The bug this guards against: the row let its text column shrink without a floor, so in a
    /// narrow pane the label lost the negotiation to the control beside it and wrapped one letter
    /// per line — a nine-line "Symbol" in a row that should be two. Measuring the height is how
    /// you tell, because the shredded layout is a perfectly valid one.
    @Test("A settings row does not shred its label in a narrow pane")
    func settingsRowStaysReadableWhenNarrow() {
        func height(inPaneOf width: CGFloat) -> CGFloat {
            let row = SettingsRow(symbol: "star", title: "Symbol", detail: "Any SF Symbol name.") {
                // Stands in for the mode editor's name field, the widest control on any row.
                Color.clear.frame(width: 200, height: 22)
            }
            .frame(width: width)

            let host = NSHostingView(rootView: row)
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        let roomy = height(inPaneOf: 600)
        let narrow = height(inPaneOf: 300)
        // Stacking costs one control's height. Shredding cost eight lines of text.
        #expect(narrow < roomy * 2)
    }

    @Test("The menu bar content builds")
    func rendersMenuBar() {
        let (state, temp) = makeState()
        render(MenuBarContent().environment(state), size: CGSize(width: 260, height: 400))
        _ = temp
    }
}
