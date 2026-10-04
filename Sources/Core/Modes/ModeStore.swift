import Foundation
import Observation

/// Holds the mode list and decides which one applies right now.
@MainActor
@Observable
final class ModeStore {
    private(set) var modes: [Mode] = []

    @ObservationIgnored private let file: JSONFileStore<[Mode]>

    init(directory: URL = AppDirectories.support) {
        file = JSONFileStore(fileName: "modes.json", directory: directory)
        modes = file.load() ?? Mode.builtIns
        // A file written by an older build can be missing a mode added since. Re-adding by id
        // keeps the user's edits to the modes they already have.
        let known = Set(modes.map(\.id))
        let missing = Mode.builtIns.filter { !known.contains($0.id) }
        if !missing.isEmpty {
            modes.append(contentsOf: missing)
            save()
        }
    }

    // MARK: - Selection

    /// The mode to use for one dictation.
    ///
    /// App matching wins over the saved selection when auto-switch is on — that is the entire
    /// point of it. Everything falls back to the first mode rather than to nothing, because a
    /// dictation must never fail for want of a mode.
    func resolve(settings: RefinementSettings, frontmostBundleID: String?) -> Mode {
        if settings.autoSwitchByApp, let match = modes.first(where: { $0.claims(bundleID: frontmostBundleID) }) {
            return match
        }
        if let id = settings.activeModeID, let chosen = modes.first(where: { $0.id == id }) {
            return chosen
        }
        return modes.first ?? Mode.builtIns[0]
    }

    /// Whether anything would use the clipboard if it were read — as reference for the model, or
    /// as text to paste.
    ///
    /// `DictationController` asks before reading it at all, so with every mode's toggles off the
    /// app never touches the clipboard except to paste — which is the claim the feature has to be
    /// able to make. Dictation modes only: an assistant mode reads it by definition, and "Ask" ships
    /// with every copy of the app, so counting it here would put the clipboard in reach of every
    /// dictation of everyone who never chose it. See `activeAssistant`.
    var anyModeReadsClipboard: Bool {
        modes.contains { $0.kind == .dictation && ($0.usesClipboardContext || $0.pastesClipboard) }
    }

    /// The assistant mode the person has chosen, if the chosen mode is one — whether or not it
    /// would be the one used right now. What `AppState` asks when a mode is chosen: choosing it is
    /// what brings its model.
    func activeAssistant(settings: RefinementSettings) -> Mode? {
        guard let id = settings.activeModeID,
              let mode = modes.first(where: { $0.id == id }),
              mode.kind == .assistant
        else { return nil }
        return mode
    }

    /// Whether a mode could ask the model to look for a request for the clipboard — which is the
    /// only thing worth getting ready ahead of time.
    var anyModePastesClipboard: Bool {
        modes.contains(where: \.pastesClipboard)
    }

    /// The assistant mode that this dictation would use, if it would use one.
    ///
    /// `resolve`, so an app that claims a dictation mode wins over a chosen assistant when "Switch
    /// by app" is on — and the clipboard is then not read for an assistant that will not run. Asked
    /// before recording starts, to decide whether to read the clipboard at all.
    func assistantInForce(settings: RefinementSettings, frontmostBundleID: String?) -> Mode? {
        let mode = resolve(settings: settings, frontmostBundleID: frontmostBundleID)
        return mode.kind == .assistant ? mode : nil
    }

    // MARK: - Editing

    func update(_ mode: Mode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
        save()
    }

    @discardableResult
    func add(name: String = "New mode", kind: ModeKind = .dictation) -> Mode {
        let mode = Mode(
            name: name,
            symbol: kind == .assistant ? "wand.and.stars" : "sparkles",
            kind: kind,
            instructions: kind == .assistant ? Mode.assistantInstructions : Mode.builtIns[0].instructions
        )
        modes.append(mode)
        save()
        return mode
    }

    /// Built-in modes cannot be deleted; they can be edited, and reset back to what shipped.
    func delete(_ id: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == id }), !modes[index].isBuiltIn else { return }
        modes.remove(at: index)
        save()
    }

    func resetToShipped(_ id: UUID) {
        guard let shipped = Mode.builtIns.first(where: { $0.id == id }),
              let index = modes.firstIndex(where: { $0.id == id })
        else { return }
        modes[index] = shipped
        save()
    }

    func flush() { file.flush() }

    private func save() { file.save(modes) }
}
