import SwiftUI

/// Modes: the list on the left, the editor on the right.
struct ModesView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: UUID?

    var body: some View {
        // A plain HStack with an explicit width, not an HSplitView. HSplitView sizes each pane to
        // its content's ideal width, and the editor's ideal width is wider than the window — which
        // pushed the right-hand controls off the edge of the screen.
        HStack(spacing: 0) {
            list
                .frame(width: 220)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Selecting eagerly rather than in `onAppear`: the first frame would otherwise render
        // "No mode selected" over a list that plainly has modes in it.
        // The mode in use when there is one: this screen is mostly opened to change the mode you
        // are using, and landing on the first in the list instead is a click every time.
        .task {
            let chosen = appState.settings.settings.refinement.activeModeID
            selection = selection
                ?? appState.modes.modes.first { $0.id == chosen }?.id
                ?? appState.modes.modes.first?.id
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(appState.modes.modes) { mode in
                    // Explicit HStack for the same reason as the main sidebar: `Label`'s icon lands
                    // in the list's icon gutter, which the sidebar style clips.
                    HStack(spacing: 8) {
                        SectionIcon(symbol: mode.symbol, tint: mode.tint.color, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.name).font(.system(size: 13, weight: .medium))
                            if mode.kind == .assistant {
                                Text("Assistant")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else if !mode.appBundleIDs.isEmpty {
                                Text("\(mode.appBundleIDs.count) app\(mode.appBundleIDs.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(mode.id)
                }
                // Drag a row to reorder. The order is shared with the menu bar, Configuration and
                // the pill's mode picker.
                .onMove { source, destination in
                    appState.modes.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Menu {
                    Button("Dictation mode") { selection = appState.modes.add().id }
                    Button("Assistant mode") { selection = appState.modes.add(name: "New assistant", kind: .assistant).id }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a mode")

                Button {
                    guard let selection else { return }
                    appState.modes.delete(selection)
                    self.selection = appState.modes.modes.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete the selected mode")
                .disabled(selectedMode.map(\.isBuiltIn) ?? true)

                Spacer()

                Text("Drag to reorder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            // Roomier than a plain 8 on purpose. With the sidebar collapsed this list is the
            // leftmost thing in the window, and the window's rounded corner cuts through anything
            // sitting tight against it.
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let mode = selectedMode {
            ModeEditor(mode: mode)
                .id(mode.id)
        } else {
            EmptyStateView(
                symbol: "sparkles",
                title: "No mode selected",
                message: "Pick a mode on the left, or add one."
            )
        }
    }

    private var selectedMode: Mode? {
        appState.modes.modes.first { $0.id == selection }
    }
}

// MARK: - Editor

private struct ModeEditor: View {
    @Environment(AppState.self) private var appState

    /// Edited locally and written back on change. Binding straight into the store would rewrite
    /// the JSON file on every keystroke in the prompt field.
    @State private var draft: Mode

    init(mode: Mode) {
        _draft = State(initialValue: mode)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Mode") {
                SettingsRow(symbol: "textformat", title: "Name") {
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110, idealWidth: 200, maxWidth: 200)
                }
                RowDivider()
                SettingsRow(
                    symbol: "arrow.left.arrow.right",
                    title: "What it does",
                    detail: draft.isBuiltIn ? "Built-in modes keep what they do." : nil
                ) {
                    Picker("What it does", selection: $draft.kind) {
                        ForEach(ModeKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .disabled(draft.isBuiltIn)
                }
                RowDivider()
                SettingsRow(
                    symbol: "square.grid.2x2",
                    title: "Icon",
                    detail: "Shown beside this mode in the list on the left."
                ) {
                    ModeIconButton(symbol: $draft.symbol, tint: draft.tint)
                }
                RowDivider()
                SettingsRow(symbol: "paintpalette", title: "Colour") {
                    TintSwatches(tint: $draft.tint)
                }
            }

            if draft.kind == .assistant {
                assistantSections
            }

            if draft.kind == .dictation {
                SettingsSection(
                    title: "Cleanup rules",
                    subtitle: "These run on every dictation, instantly, with no model involved."
                ) {
                    toggle("Remove filler words", "\"um\", \"uh\", and the local equivalents.", "scissors", $draft.cleanup.removeFillers)
                    RowDivider()
                    toggle("Resolve self-corrections", "\"send it Tuesday, no, Wednesday\" becomes \"send it Wednesday\".", "arrow.uturn.backward", $draft.cleanup.resolveSelfCorrections)
                    RowDivider()
                    toggle("Spoken punctuation", "Saying \"comma\" types a comma.", "text.quote", $draft.cleanup.spokenPunctuation)
                    RowDivider()
                    toggle("Sentence case", "Capitalise the first word of each sentence. Never lowercases anything.", "textformat.abc", $draft.cleanup.sentenceCase)
                    RowDivider()
                    toggle("Apply vocabulary", "Use the spellings from the Vocabulary screen.", "book", $draft.cleanup.applyVocabulary)
                    RowDivider()
                    toggle("Tidy whitespace", "Collapse double spaces and fix spacing around punctuation.", "space", $draft.cleanup.tidyWhitespace)
                }

                SettingsSection(
                    title: "Model instructions",
                    subtitle: appState.onDeviceRefiner.availability.isAvailable
                        ? "What Gemma 4 is told to do with this mode's transcripts. Leave empty to skip the model for this mode."
                        : "What Gemma 4 is told to do, once it is ready. \(appState.onDeviceRefiner.availability.explanation)"
                ) {
                    TextEditor(text: $draft.instructions)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 130)
                        .padding(10)
                        .scrollContentBackground(.hidden)

                    RowDivider()

                    toggle(
                        "Use the clipboard as context",
                        "Shows the model what you have copied, so it spells the names and terms in it the same way. It is never pasted, it never leaves the Mac, and a password copied from a password manager is skipped.",
                        "doc.on.clipboard",
                        $draft.usesClipboardContext
                    )
                    .disabled(!modelIsAvailable)
                }

                SettingsSection(
                    title: "Clipboard",
                    subtitle: modelIsAvailable
                        ? "For handing something you copied to the app you are dictating into. Gemma 4 reads your sentence to find where you asked for it."
                        : "Needs Gemma 4, which is what finds where in your sentence you asked for the clipboard. \(appState.onDeviceRefiner.availability.explanation)"
                ) {
                    toggle(
                        "Paste the clipboard where you ask for it",
                        "Copy a stack trace or a message, say what you want done about it, and both arrive in one paste — exactly as it was copied. Ask for it mid-sentence, in any language and any wording, and it lands right there. Say nothing about it, or only talk about it, and nothing is pasted, so this can stay on. It adds about half a second. Gemma 4 reads only your sentence, to find the words that ask; the app puts the copied text in itself, so nothing is reworded or shortened. It never leaves the Mac, it is not kept in History, and a password copied from a password manager is skipped.",
                        "doc.on.clipboard.fill",
                        $draft.pastesClipboard
                    )
                    // Both clipboard toggles are downstream of the model: one shows it what you copied,
                    // the other pastes it where the model said it goes. With no model there is nothing
                    // either can do, and the app does not read the clipboard at all — so the switch is
                    // off rather than on and quietly doing nothing.
                    .disabled(!modelIsAvailable)
                }

                SettingsSection(
                    title: "Switch to this mode in",
                    subtitle: "Bundle identifiers, one per line. When \"Switch modes by app\" is on, focusing one of these picks this mode."
                ) {
                    TextEditor(text: bundleIDsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 90)
                        .padding(10)
                        .scrollContentBackground(.hidden)

                    RowDivider()

                    SettingsRow(
                        symbol: "questionmark.circle",
                        title: "Find an app's identifier",
                        detail: "Terminal: osascript -e 'id of app \"Slack\"'"
                    ) {
                        EmptyView()
                    }
                }
            }

            if draft.isBuiltIn {
                SettingsSection(title: "Built-in mode") {
                    SettingsRow(
                        symbol: "arrow.counterclockwise",
                        title: "Reset to how it shipped",
                        detail: "Built-in modes cannot be deleted, only reset."
                    ) {
                        Button("Reset") {
                            appState.modes.resetToShipped(draft.id)
                            if let restored = appState.modes.modes.first(where: { $0.id == draft.id }) {
                                draft = restored
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onChange(of: draft) { old, newValue in
            appState.modes.update(newValue)
            if old.kind != newValue.kind {
                // The instructions are what the mode *is*, and the two kinds' are not
                // interchangeable: a cleanup prompt on an assistant answers nothing, and an
                // assistant's on a dictation rewrites it. Swapped only when still the stock text —
                // someone who wrote their own keeps it.
                if old.instructions == Self.stockInstructions(for: old.kind) {
                    draft.instructions = Self.stockInstructions(for: newValue.kind)
                }
                // A mode that has just become an assistant while it is the chosen one needs its
                // model, the same as choosing it would.
                appState.prepareAssistantIfChosen()
            }
        }
    }

    private static func stockInstructions(for kind: ModeKind) -> String {
        kind == .assistant ? Mode.assistantInstructions : Mode.builtIns[0].instructions
    }

    /// What an assistant mode has instead of cleanup rules and the clipboard switches: nothing it
    /// does is a tidy-up, and the clipboard is not an option here, it is the material.
    @ViewBuilder
    private var assistantSections: some View {
        SettingsSection(
            title: "Assistant",
            subtitle: "Copy something, hold the key, and say what you want done to it — \"make this politer\", \"summarise this in three points\", \"reply, say I'll do it Tuesday\". The answer is typed where your cursor is, and Escape stops it. Copy nothing and it writes what you ask for."
        ) {
            SettingsRow(
                symbol: "lock.shield",
                title: "What you copy stays on this Mac",
                detail: "The first \(ClipboardContext.materialLimit.formatted()) characters of it go to the model on this Mac, and nowhere else. It is not kept in History, and a password copied from a password manager is skipped."
            )
            RowDivider()
            toggle(
                "Think before answering",
                "The model works the problem out before it writes. Better for summaries and anything with reasoning in it, and it adds seconds before the first word. Off, the answer starts almost at once.",
                "brain",
                $draft.thinks
            )
            RowDivider()
            SettingsRow(
                symbol: "cpu",
                title: appState.assistantModel.model.name,
                detail: appState.assistantModel.availability.assistantExplanation(for: appState.assistantModel.model)
            ) {
                assistantModelControl
            }
        }

        SettingsSection(
            title: "Instructions",
            subtitle: "Who the assistant is. It reads this before every request, so \"you write replies for a support desk — short, warm, no promises about dates\" is a whole assistant."
        ) {
            TextEditor(text: $draft.instructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 130)
                .padding(10)
                .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var assistantModelControl: some View {
        switch appState.assistantModel.availability {
        case .notDownloaded, .failed:
            Button("Download") { Task { await appState.models.download(ModelLibrary.assistantGemmaID) } }
                .buttonStyle(.borderedProminent)
        case .downloading(let fraction):
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView().controlSize(.small)
        case .downloaded, .available:
            EmptyView()
        }
    }

    private var bundleIDsText: Binding<String> {
        Binding(
            get: { draft.appBundleIDs.joined(separator: "\n") },
            set: { text in
                draft.appBundleIDs = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// Whether the on-device model could run at all — downloaded and loaded, matching the "Model
    /// instructions" section above — the Configuration switch is named in the prose instead,
    /// because a control that greys out from another screen reads as broken rather than as a
    /// dependency.
    private var modelIsAvailable: Bool {
        appState.onDeviceRefiner.availability.isAvailable
    }

    private func toggle(_ title: String, _ detail: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            Toggle("", isOn: value).toggleStyle(.switch)
        }
    }
}
