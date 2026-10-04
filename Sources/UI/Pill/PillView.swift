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

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .frame(minWidth: 108)
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.82))
                if model.phase.isProcessing {
                    // Clipped rather than masked so the sweep stops at the fill and leaves the
                    // border below to draw the edge at full strength.
                    ProcessingSweep()
                        .clipShape(Capsule(style: .continuous))
                }
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(model.phase.isProcessing ? 0.22 : 0.12), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .padding(Self.shadowMargin)
        .animation(.smooth(duration: 0.18), value: model.phase)
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
                Text(target).lineLimit(1)
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
