import SwiftUI

struct PillView: View {
    @Environment(PillModel.self) private var model

    /// Transparent margin left around the capsule for the shadow to fall into.
    ///
    /// The window is sized to this view, and the window server clips to the window frame. Without
    /// the margin the blur is cut off square and the pill sits inside a visible grey rectangle —
    /// which reads as a bug in the pill, not as a missing pixel of shadow. Must cover the blur
    /// radius plus the downward offset.
    static let shadowMargin: CGFloat = 24

    /// The open pill. Wide enough for eight mode chips without scrolling, which is more than the
    /// shipped six and enough for most people's own; past that the strip scrolls.
    static let openWidth: CGFloat = 360
    static let openHeight: CGFloat = 104

    /// What the capsule is while listening, as a number. The width has to be a number on both
    /// sides of the animation to grow from one to the other; every other phase is as wide as its
    /// label, which SwiftUI cannot interpolate from, and those snap as they always did.
    static let listeningWidth: CGFloat = 108

    private static let openCorner: CGFloat = 28
    private static let closedCorner: CGFloat = 22

    var body: some View {
        let isOpen = model.isOpen
        let corner = isOpen ? Self.openCorner : Self.closedCorner

        HStack(spacing: 10) {
            if isOpen {
                ModePicker(model: model)
                    .transition(.blurReplace)
            } else {
                content
                    .padding(.horizontal, 18)
                    .transition(.blurReplace)
            }
        }
        .frame(width: surfaceWidth(isOpen: isOpen), height: isOpen ? Self.openHeight : 44)
        .frame(minWidth: Self.listeningWidth)
        // The picker is laid out at its full size from the first frame, so while the capsule is
        // still small it would be drawn outside it, as blurred icons floating above the pill. The
        // clip follows the capsule as it grows, which is what makes it read as opening.
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.black.opacity(0.82))
                if model.phase.isProcessing {
                    // Clipped rather than masked so the sweep stops at the fill and leaves the
                    // border below to draw the edge at full strength.
                    ProcessingSweep()
                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(model.phase.isProcessing ? 0.22 : 0.12), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .padding(Self.shadowMargin)
        // The window is as big as the open pill for the whole of a dictation that has a picker,
        // and the capsule sits at its bottom edge. A window that grew with the animation would
        // have to be resized in step with it from outside SwiftUI, and the two never quite agree;
        // a window that is already big has nothing to resize, and its empty part is transparent.
        .frame(
            width: model.hasPicker ? Self.openWidth + Self.shadowMargin * 2 : nil,
            height: model.hasPicker ? Self.openHeight + Self.shadowMargin * 2 : nil,
            alignment: .bottom
        )
        .animation(.smooth(duration: 0.18), value: model.phase)
        .animation(.spring(response: 0.46, dampingFraction: 0.82), value: isOpen)
    }

    private func surfaceWidth(isOpen: Bool) -> CGFloat? {
        if isOpen { return Self.openWidth }
        return model.hasPicker && model.phase == .listening ? Self.listeningWidth : nil
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            AudioBars(values: model.bars)
        case .transcribing:
            BusyLabel(text: "Transcribing", symbol: "waveform")
        case .formatting:
            BusyLabel(text: "Cleaning up", symbol: "sparkles")
        case .answering:
            BusyLabel(text: "Writing", symbol: "wand.and.stars")
        case .success(let target):
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                // Its natural width. The window is fitted to the label and a label that is then
                // squeezed to what the window turned out to be loses its last letters.
                Text(target).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
        case .failure(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: 320)
        }
    }
}

/// The inside of the open pill: the level bars you already had, which mode is chosen, and every
/// mode as an icon to click.
///
/// The chosen mode is named once, in the corner, rather than every chip carrying a label: eight
/// labels do not fit in a pill this size, and an icon the person has chosen themselves is what they
/// look for. The name is the one thing a colour and a glyph cannot say — so pointing at a chip puts
/// that chip's name in the corner, and the corner goes back to the chosen mode when the pointer
/// leaves. Eight glyphs are not all readable at a glance, and a click is the wrong way to find out.
private struct ModePicker: View {
    let model: PillModel

    @State private var hoveredID: UUID?

    /// What the corner names: the chip under the pointer, else the one in use.
    private var named: PillModeOption? {
        model.modeOptions.first { $0.id == hoveredID }
            ?? model.modeOptions.first { $0.id == model.selectedModeID }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                AudioBars(values: model.bars)
                Spacer(minLength: 12)
                if let named {
                    HStack(spacing: 6) {
                        Image(systemName: named.symbol)
                        Text(named.name).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .id(named.id)
                    .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 22)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.modeOptions) { option in
                            ModeChip(
                                option: option,
                                isSelected: option.id == model.selectedModeID,
                                onHover: { hover(option.id, $0) }
                            ) {
                                model.selectedModeID = option.id
                                model.onSelectMode?(option.id)
                            }
                            .id(option.id)
                        }
                    }
                    // Centred while it fits, and the whole strip when it does not: the content is
                    // at least as wide as the pill, so a few modes sit in the middle.
                    .frame(minWidth: PillView.openWidth, alignment: .center)
                }
                .onChange(of: model.selectedModeID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = model.selectedModeID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.2), value: named?.id)
    }

    /// Leaving one chip and entering the next can arrive in either order, so only the chip that is
    /// still hovered may clear it — otherwise the corner would go back to the chosen mode for a
    /// frame between two chips.
    private func hover(_ id: UUID, _ isInside: Bool) {
        if isInside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }
}

/// One mode: its own icon, the way it looks in the Modes list, ringed when it is the one in use.
private struct ModeChip: View {
    let option: PillModeOption
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    private static let size: CGFloat = 34

    var body: some View {
        Button(action: action) {
            SectionIcon(symbol: option.symbol, tint: option.tint.color, size: Self.size)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.size * 0.28 + 3, style: .continuous)
                        .strokeBorder(.white, lineWidth: isSelected ? 2 : 0)
                }
                .opacity(isSelected ? 1 : 0.7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AudioBars: View {
    let values: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .fill(.white)
                    // A floor keeps the bars visible during silence, so the pill reads as
                    // "listening" rather than "frozen".
                    .frame(width: 4, height: max(4, 26 * value))
            }
        }
        .frame(height: 26)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), values: values)
    }
}

/// A band of light crossing the capsule while the app is transcribing or cleaning up.
///
/// Those two stages have nothing to show — no audio bars, no text yet — and a still pill during a
/// slow on-device model reads as a hang. The sweep is one animated `offset`, so Core Animation
/// runs it off the main thread and it costs nothing while the model works.
private struct ProcessingSweep: View {
    @State private var travelled = false

    /// How much of the capsule the band covers. Wide enough to be a wash of light rather than a
    /// stripe, which would read as a loading bar and promise progress this cannot know.
    private static let bandFraction: CGFloat = 0.55

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = width * Self.bandFraction
            LinearGradient(
                colors: [.clear, .white.opacity(0.18), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: travelled ? width : -band)
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: travelled)
            .onAppear { travelled = true }
        }
    }
}

private struct BusyLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                // The symbol's own layers cycle rather than the whole glyph fading. Fading it out
                // made the pill look like it was dismissing itself half the time.
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
    }
}

private extension View {
    /// `animation(_:value:)` needs an `Equatable`; an array of doubles qualifies but reads badly
    /// inline, so this keeps the call site honest about animating the whole set together.
    func animation(_ animation: Animation?, values: [Double]) -> some View {
        self.animation(animation, value: values)
    }
}
