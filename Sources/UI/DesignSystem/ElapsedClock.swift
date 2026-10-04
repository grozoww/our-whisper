import SwiftUI

/// "2:41", counting up from `since`, for a wait that has no progress to show.
///
/// A spinner alone cannot be told from a hang. A clock that moves is the proof that the app is
/// alive, and the number is how long it has been — which is what someone deciding whether to give
/// up actually wants to know.
struct ElapsedClock: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since ?? context.date)))
                .monospacedDigit()
        }
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
