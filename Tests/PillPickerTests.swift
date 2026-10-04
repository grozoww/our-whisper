import AppKit
import SwiftUI
import Testing

@testable import OurWhisper

/// The pill that opens into a mode picker, and the list that can be reordered.
///
/// The animation itself is looked at, not tested: `OURWHISPER_SCREENSHOT=pill.opening` photographs
/// it a frame at a time. What is here is what decides whether it is safe — that a pill which is not
/// open takes no clicks, that the small style is untouched, and that a mode picked in it is for one
/// dictation.
@MainActor
@Suite("Pill: mode picker", .serialized)
struct PillPickerTests {
    private func options(_ count: Int = 6) -> [PillModeOption] {
        (0..<count).map { index in
            PillModeOption(Mode(name: "Mode \(index)", symbol: "star", tint: .blue, instructions: ""))
        }
    }

    // MARK: - The model

    @Test("The picker is open only while listening, and only when there is something to pick")
    func isOpenTable() {
        let model = PillModel()
        model.modeOptions = options()

        model.isExpanded = true
        model.phase = .listening
        #expect(model.isOpen)

        // Recording stopped: it closes by itself, with no one having to remember to.
        for phase in [PillModel.Phase.transcribing, .formatting, .answering, .success("Slack"), .failure("no")] {
            model.phase = phase
            #expect(model.isOpen == false, "\(phase) must not be wide")
        }

        model.phase = .listening
        model.isExpanded = false
        #expect(model.isOpen == false)  // not asked to open yet

        model.isExpanded = true
        model.modeOptions = []
        #expect(model.isOpen == false)  // nothing to pick
    }

    @Test("A new pill forgets the last one's picker")
    func resetClearsThePicker() {
        let model = PillModel()
        model.modeOptions = options()
        model.selectedModeID = model.modeOptions[0].id
        model.isExpanded = true
        model.onSelectMode = { _ in }

        model.reset()

        #expect(model.modeOptions.isEmpty)
        #expect(model.selectedModeID == nil)
        #expect(model.isExpanded == false)
        #expect(model.onSelectMode == nil)
    }

    @Test("An option carries what is drawn and nothing else")
    func optionFromMode() {
        let mode = Mode(name: "Email", symbol: "envelope", tint: .indigo, instructions: "long prompt", appBundleIDs: ["x"])
        let option = PillModeOption(mode)
        #expect(option.id == mode.id)
        #expect(option.name == "Email")
        #expect(option.symbol == "envelope")
        #expect(option.tint == .indigo)
    }

    @Test("The picker offers the modes in the order of the list")
    func pickerFollowsTheOrder() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        store.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)  // Raw to the top
        #expect(store.modes.map(PillModeOption.init).first?.name == "Raw")
    }

    // MARK: - Clicks

    @Test("A pill that is not open takes no clicks, in either style")
    func closedPillIgnoresTheMouse() {
        let pill = PillWindowController()
        pill.show()
        #expect(pill.takesClicks == false)

        pill.offerModes(options(), selected: nil) { _ in }
        // Offered, but not yet opened: still a pill and not a window.
        #expect(pill.takesClicks == false)
        pill.hide()
    }

    @Test("The open pill takes clicks, and gives them back the moment recording stops")
    func openPillTakesClicks() async {
        let pill = PillWindowController()
        pill.show()
        await pill.offerModes(options(), selected: nil) { _ in }.value

        #expect(pill.pillModel.isOpen)
        #expect(pill.takesClicks)

        pill.setPhase(.transcribing)
        #expect(pill.pillModel.isOpen == false)
        #expect(pill.takesClicks == false)
        pill.hide()
    }

    @Test("Stopping before it has opened means it never does")
    func stoppingFirstCancelsTheOpening() async {
        let pill = PillWindowController()
        pill.show()
        let opening = pill.offerModes(options(), selected: nil) { _ in }
        pill.setPhase(.transcribing)  // the key was released within the delay
        await opening.value

        #expect(pill.pillModel.isExpanded == false)
        #expect(pill.takesClicks == false)
        pill.hide()
    }

    @Test("The next pill is not the last one's picker")
    func showClearsThePicker() async {
        let pill = PillWindowController()
        pill.show()
        await pill.offerModes(options(), selected: nil) { _ in }.value
        pill.show()

        #expect(pill.pillModel.modeOptions.isEmpty)
        #expect(pill.takesClicks == false)
        pill.hide()
    }

    @Test("Choosing a mode reports it, and moves the ring")
    func choosing() {
        let pill = PillWindowController()
        let opts = options()
        var heard: UUID?
        pill.show()
        pill.offerModes(opts, selected: opts[0].id) { heard = $0 }

        pill.pillModel.selectedModeID = opts[2].id
        pill.pillModel.onSelectMode?(opts[2].id)

        #expect(heard == opts[2].id)
        pill.selectMode(opts[3].id)
        #expect(pill.pillModel.selectedModeID == opts[3].id)
        pill.hide()
    }

    // MARK: - Size

    private func size(_ model: PillModel) -> CGSize {
        let host = NSHostingView(rootView: PillView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test("The small style is the size it always was")
    func smallIsUntouched() {
        let model = PillModel()
        let fitted = size(model)
        #expect(fitted.height == 44 + PillView.shadowMargin * 2)
        #expect(fitted.width >= PillView.listeningWidth + PillView.shadowMargin * 2)
        #expect(fitted.width < PillView.openWidth)
    }

    @Test("A pill with a picker is as big as the open one for the whole dictation, however many modes")
    func pickerWindowIsFixed() {
        let big = CGSize(
            width: PillView.openWidth + PillView.shadowMargin * 2,
            height: PillView.openHeight + PillView.shadowMargin * 2
        )
        for count in [1, 6, 30] {
            let model = PillModel()
            model.modeOptions = options(count)
            // Closed, open, and mid-dictation after it closed: the window must not move under it.
            for (expanded, phase) in [(false, PillModel.Phase.listening), (true, .listening), (true, .transcribing)] {
                model.isExpanded = expanded
                model.phase = phase
                #expect(size(model) == big, "\(count) modes, expanded \(expanded), \(phase)")
            }
        }
    }

    @Test("The picker builds with one mode, six and thirty, in every phase")
    func rendersEveryShape() {
        for count in [1, 6, 30] {
            for phase in [PillModel.Phase.listening, .transcribing, .answering, .success("Slack"), .failure("Could not paste.")] {
                let model = PillModel()
                model.modeOptions = options(count)
                model.selectedModeID = model.modeOptions[count / 2].id
                model.isExpanded = true
                model.phase = phase

                let host = NSHostingView(rootView: PillView().environment(model))
                host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                window.contentView = nil
            }
        }
    }

    // MARK: - What is chosen for one dictation

    @Test("The clipboard follows the mode that was clicked", arguments: [
        // (kind, reads it, model can run, assistant can run, wants it)
        (ModeKind.dictation, true, true, false, true),
        (.dictation, true, false, true, false),   // no model, no clipboard
        (.dictation, false, true, true, false),   // a mode that does not use it
        (.assistant, false, false, true, true),   // an assistant is about what you copied
        (.assistant, false, true, false, false),  // …when its model can run
    ])
    func clipboardFollowsTheMode(kind: ModeKind, reads: Bool, modelCanRun: Bool, assistantMayRun: Bool, wants: Bool) {
        var mode = Mode(name: "m", symbol: "star", kind: kind, instructions: "x")
        mode.usesClipboardContext = reads
        #expect(DictationController.needsClipboard(for: mode, modelCanRun: modelCanRun, assistantMayRun: assistantMayRun) == wants)
    }
}

@Suite("Pill: settings")
struct PillStyleSettingsTests {
    @Test("A settings file from before the style existed gets the small pill")
    func oldFilesAreSmall() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"appearance":{"showPill":true}}"#.utf8))
        #expect(settings.appearance.pillStyle == .compact)
        #expect(settings.appearance.showPill)
    }

    @Test("A style this version does not know costs the style, not the file")
    func unknownStyle() throws {
        let json = #"{"appearance":{"pillStyle":"hologram","showInDock":true}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.appearance.pillStyle == .compact)
        #expect(settings.appearance.showInDock)
    }

    @Test("The chosen style survives a round trip")
    func roundTrip() throws {
        var settings = Settings()
        settings.appearance.pillStyle = .withModes
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appearance.pillStyle == .withModes)
    }

    @Test("Every style has a name to show")
    func titles() {
        #expect(PillStyle.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@MainActor
@Suite("Modes: order")
struct ModeOrderTests {
    private func names(_ store: ModeStore) -> [String] { store.modes.map(\.name) }

    @Test("A mode dragged up goes in front of the one it was dropped on")
    func movesUp() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = names(store)

        store.move(fromOffsets: IndexSet(integer: 4), toOffset: 1)
        #expect(names(store) == [before[0], before[4], before[1], before[2], before[3]] + before.dropFirst(5))
    }

    @Test("A mode dragged down lands after the one above the drop point")
    func movesDown() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = names(store)

        // `onMove` reports the offset *before* removal: dropping row 0 "at 3" puts it after row 2.
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(names(store) == [before[1], before[2], before[0]] + before.dropFirst(3))
    }

    @Test("A mode can be dropped at the very end")
    func movesToTheEnd() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = names(store)

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: before.count)
        #expect(names(store) == Array(before.dropFirst()) + [before[0]])
    }

    @Test("Dropping a mode where it already is changes nothing and writes nothing")
    func noOp() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = store.modes

        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 2)
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 3)
        #expect(store.modes == before)
    }

    @Test("Nothing is lost or duplicated by any move")
    func keepsEveryMode() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let ids = Set(store.modes.map(\.id))

        for (from, to) in [(0, 5), (5, 0), (3, 1), (1, 4), (2, 2)] {
            store.move(fromOffsets: IndexSet(integer: from), toOffset: to)
            #expect(Set(store.modes.map(\.id)) == ids)
            #expect(store.modes.count == ids.count)
        }
    }

    @Test("The order is kept in the file")
    func persists() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        store.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        store.flush()

        #expect(names(ModeStore(directory: temp.url)).first == "Raw")
    }

    @Test("Several rows can be moved together")
    func movesMany() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        let before = names(store)

        store.move(fromOffsets: IndexSet([1, 2]), toOffset: 0)
        #expect(names(store).prefix(3) == [before[1], before[2], before[0]])
    }

    @Test("With no mode chosen, the fallback is General wherever it has been dragged")
    func fallbackIsGeneral() {
        // The list used to fall back to its first mode. Once the list can be reordered that is
        // whichever mode was dragged to the top, and Raw pastes what the speech model heard.
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        store.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(store.modes.first?.name == "Raw")

        var settings = RefinementSettings()
        settings.activeModeID = nil
        settings.autoSwitchByApp = false
        #expect(store.resolve(settings: settings, frontmostBundleID: nil).name == "General")
    }
}
