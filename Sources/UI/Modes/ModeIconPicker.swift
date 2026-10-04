import SwiftUI

/// The mode editor's icon control: the icon as it will look in the list, which opens the picker.
///
/// This replaced a text field captioned "Any SF Symbol name", which asked people for something
/// nobody knows. The stored value did not change — it is still the plain name string — so a modes
/// file written by an older version, or by hand, opens exactly as it did.
struct ModeIconButton: View {
    @Binding var symbol: String
    let tint: ModeColor

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                // Asking the system whether a name resolves is ~30 µs, measured — a local asset
                // lookup, not the round trip to another process that the rule against questions
                // in a `body` is about.
                SectionIcon(
                    symbol: ModeSymbols.resolves(symbol) ? symbol : ModeSymbols.placeholder,
                    tint: tint.color,
                    size: 26
                )
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .help("Choose an icon")
        .accessibilityLabel("Icon")
        .accessibilityValue(ModeSymbols.symbol(named: symbol)?.keywords.first ?? symbol)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SymbolPickerPopover(symbol: $symbol, tint: tint) { isOpen = false }
        }
        // Posing for a screenshot: the popover is a window of its own, which is why it cannot be
        // photographed with the window it hangs from and has to be asked for.
        .task {
            guard ScreenshotMode.opensIconPicker else { return }
            try? await Task.sleep(for: .milliseconds(900))
            isOpen = true
        }
    }
}

/// What opens from `ModeIconButton`: a search box, the catalogue by category, and a way in for a
/// name that is not on it.
struct SymbolPickerPopover: View {
    @Binding var symbol: String
    let tint: ModeColor
    let dismiss: () -> Void

    @State private var query = ""
    @State private var customName = ""
    @FocusState private var searchFocused: Bool

    /// Seven to a row at the popover's width. Fixed-size cells rather than flexible ones: a grid of
    /// icons that stretches to fill reads as buttons, and one that keeps its size reads as a palette.
    private static let columns = [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 4)]

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search: mail, почта, code…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    // Return takes the best match, so finding an icon never needs the mouse.
                    if let first = results.first { choose(first.name) }
                }
                .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if query.isEmpty, uncatalogued {
                        section("Current") { uncataloguedCell }
                    }

                    if query.isEmpty {
                        ForEach(ModeSymbol.Category.allCases) { category in
                            section(category.title) {
                                ForEach(ModeSymbols.symbols(in: category)) { cell(for: $0) }
                            }
                        }
                    } else if results.isEmpty {
                        Text("No icon matches “\(query)”. Try another word, or type a symbol name below.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        section("Results") {
                            ForEach(results) { cell(for: $0) }
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: 300)

            Divider()

            customRow
        }
        .frame(width: 330)
        // Opaque on purpose. A popover's own material blurs whatever is behind it, and behind this
        // one sit the editor's coloured switches — they showed through as orange smudges under
        // icons, which read as some of them being selected.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
    }

    // MARK: - Pieces

    private var results: [ModeSymbol] {
        ModeSymbols.search(query)
    }

    /// A name the list does not know — a hand-edited file, or one typed in the row below. It is
    /// shown as the selected icon so the picker never opens looking like nothing is chosen.
    private var uncatalogued: Bool {
        ModeSymbols.symbol(named: symbol) == nil
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    private func cell(for entry: ModeSymbol) -> some View {
        SymbolCell(
            name: entry.name,
            label: entry.keywords.first ?? entry.name,
            isSelected: symbol == entry.name,
            tint: tint.color
        ) { choose(entry.name) }
    }

    /// The cell for the current name when it is not on the list, drawn as the placeholder if the
    /// system has no such symbol — a typo should look like one, not like an empty tile.
    private var uncataloguedCell: some View {
        SymbolCell(
            name: ModeSymbols.resolves(symbol) ? symbol : ModeSymbols.placeholder,
            label: symbol,
            isSelected: true,
            tint: tint.color,
            help: symbol
        ) { choose(symbol) }
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Or any SF Symbol name", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useCustomName)
                Button("Use", action: useCustomName)
                    .disabled(!customNameResolves)
            }
            if !trimmedCustomName.isEmpty, !customNameResolves {
                Text("This Mac has no symbol with that name.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var trimmedCustomName: String {
        customName.trimmingCharacters(in: .whitespaces)
    }

    private var customNameResolves: Bool {
        ModeSymbols.resolves(trimmedCustomName)
    }

    private func useCustomName() {
        guard customNameResolves else { return }
        choose(trimmedCustomName)
    }

    private func choose(_ name: String) {
        symbol = name
        dismiss()
    }
}

/// One icon in the grid. The name is the tooltip as well as the label: hovering teaches the names
/// that people were previously expected to already know.
private struct SymbolCell: View {
    let name: String
    let label: String
    let isSelected: Bool
    let tint: Color
    var help: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? tint : .primary)
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? tint.opacity(0.16) : (isHovered ? Color.primary.opacity(0.08) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? tint : .clear, lineWidth: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help ?? name)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The mode colours as chips, in place of a pop-up menu of their names: "Orange, Blue, Purple" says
/// nothing about how an icon will look, and a chip does. Thirty of them, in rows of ten, which is
/// what a pop-up menu could never have carried.
struct TintSwatches: View {
    @Binding var tint: ModeColor

    private static let size: CGFloat = 16
    private static let spacing: CGFloat = 4

    var body: some View {
        // A `Grid`, not a `LazyVGrid`: this sits in a settings row that measures its control once
        // and fixes its size, and a lazy grid has no size to give until it is laid out.
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
            ForEach(ModeColor.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(ModeColor.rows[row]) { option in
                        chip(option)
                    }
                }
            }
        }
    }

    private func chip(_ option: ModeColor) -> some View {
        let isSelected = option == tint
        return Button {
            tint = option
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: Self.size, height: Self.size)
                // A ring with a gap round the chosen one. Shape, not just colour, says which is
                // picked, for the people who cannot tell the chips apart.
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? option.color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
