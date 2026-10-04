import Observation
import SwiftUI

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
    }
}
