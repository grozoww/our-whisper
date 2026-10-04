import Foundation

/// How long to wait before asking GitHub again.
///
/// A menu bar app is not quit, it is left running — for weeks, across sleeps — so a check at launch
/// alone only ever sees what was released before the last restart. A day is one request: an update
/// reaches anyone who uses the Mac within a day of it shipping, GitHub's limit for unauthenticated
/// callers (60 an hour per address, shared by everyone behind the same router) is nowhere near, and
/// nothing is checked often enough to be a pulse. It is also what Sparkle, the usual answer on the
/// Mac, does. Releases here land on every merge, so a shorter interval would find more of them —
/// but nobody needs an update within hours, and the Check button in Configuration is one press.
///
/// The wait is measured on a clock that keeps counting while the Mac sleeps, so a check that came
/// due overnight fires the moment the lid opens — when Wi-Fi may not be back yet. A failed check is
/// therefore asked again soon rather than a whole interval later. That retry belongs to the *check*
/// only: nothing about downloading an update is ever scheduled, see `UpdateInstaller`.
enum UpdateSchedule {
    static let interval: Duration = .seconds(24 * 60 * 60)
    static let retryInterval: Duration = .seconds(15 * 60)

    /// Pure so it can be tested; the loop that sleeps lives in `AppState`.
    nonisolated static func delay(after state: UpdateChecker.State) -> Duration {
        if case .failed = state { retryInterval } else { interval }
    }
}
