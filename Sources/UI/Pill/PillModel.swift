import Observation
import SwiftUI

/// One mode in the pill's picker. A value of its own rather than a `Mode`, so the overlay, which
/// redraws at display rate, does not hold the whole of a mode — its instructions, its bundle ids —
/// to draw an icon and a name.
struct PillModeOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let symbol: String
    let tint: ModeColor

    init(_ mode: Mode) {
        id = mode.id
        name = mode.name
        symbol = mode.symbol
        tint = mode.tint
    }
}

/// What the floating pill is showing. Kept separate from `AppState` so the overlay can update at
/// display rate without invalidating the main window's view tree.
@MainActor
@Observable
final class PillModel {
    enum Phase: Equatable {
        case listening
        case transcribing
        case formatting
        /// An assistant mode is writing its answer. Its own phase, not `formatting`: that one
        /// means a sentence is being tidied, which takes a second, and this is a reply, which can
        /// take thirty and has an Escape.
        case answering
        case success(String)
        case failure(String)

        /// The stages where the user is waiting on something they cannot see. The pill animates
        /// through these so a slow model reads as working rather than as stuck.
        var isProcessing: Bool {
            self == .transcribing || self == .formatting || self == .answering
        }
    }

    var phase: Phase = .listening

    /// The modes to offer while recording, in the order of the Modes list. Empty means the pill has
    /// no picker — the small style, and every pill that is not a recording.
    var modeOptions: [PillModeOption] = []
    var selectedModeID: UUID?

    /// Asked for by `PillWindowController` a moment after the pill appears. Not enough on its own:
    /// the picker is only open while the phase is `.listening`, whatever this says.
    var isExpanded = false

    /// Called with a mode's id when one is clicked. Not observed: it is a hook, not something to draw.
    @ObservationIgnored var onSelectMode: ((UUID) -> Void)?

    var hasPicker: Bool { !modeOptions.isEmpty }

    /// Whether the capsule is the larger window with the modes in it right now. It closes by
    /// itself the moment recording stops, so the pill is never wide over a "Transcribing" label.
    var isOpen: Bool { isExpanded && hasPicker && phase == .listening }

    /// Bar heights, 0...1, newest on the right. Fixed count so the layout never reflows.
    private(set) var bars: [Double] = Array(repeating: 0.08, count: PillModel.barCount)

    static let barCount = 5

    /// Pushes one loudness sample. Called ~30 times a second while recording.
    func push(level: Float) {
        let value = Double(max(0.08, min(1, level)))
        var next = bars
        next.removeFirst()
        next.append(value)
        bars = next
    }

    func reset() {
        bars = Array(repeating: 0.08, count: Self.barCount)
        phase = .listening
        modeOptions = []
        selectedModeID = nil
        isExpanded = false
        onSelectMode = nil
    }
}
