import SwiftUI

/// The menu bar's offer of a release the user does not have yet — the one-press version of the
/// Home banner's "Update and restart".
///
/// What it says and what a press does is `row`, a pure function of the release, the installer's
/// phase and whether this build may install, so every phase can be built in a test. `phase` and
/// `refusal` are passed in rather than read here for the same reason `UpdateActions` does it: a
/// `switch` inside a `ViewBuilder` compiles whichever branch is wrong, and `refusal` is a question
/// for the security daemon that `AppState.checkForUpdate` has already asked by the time this is
/// drawn.
///
/// A menu closes when something in it is pressed, so progress is not watched live. It is there
/// for whoever opens the menu again, and `Home` is where the full story is.
struct UpdateMenuItem: View {
    struct Row: Equatable {
        enum Action: Equatable {
            case install
            case openHome
            case quit
        }

        let title: String
        let subtitle: String
        let symbol: String
        /// `nil` is a row that is shown and cannot be pressed — an update already under way.
        let action: Action?
    }

    @Environment(AppState.self) private var appState
    let release: UpdateChecker.Release
    let phase: UpdateInstaller.Phase
    let refusal: String?
    let openHome: () -> Void

    var body: some View {
        let row = Self.row(
            release: release,
            phase: phase,
            refusal: refusal,
            // Not mid-dictation: installing ends with the app quitting, and the sentence being
            // spoken would go with it. The same rule as the banner's button.
            canStart: appState.recordingState == .idle
        )

        // An `Image` and two `Text`s, not a `Label`: measured on macOS 26, a menu draws the second
        // `Text` as the line under the title only when the label is laid out flat like this. Inside
        // a `Label`'s title the subtitle is dropped without a word.
        Button {
            perform(row.action)
        } label: {
            Image(systemName: row.symbol)
            Text(row.title)
            Text(row.subtitle)
        }
        .disabled(row.action == nil)
    }

    private func perform(_ action: Row.Action?) {
        switch action {
        case .install:
            Task { await appState.installer.install(release) }
        case .openHome:
            openHome()
        case .quit:
            // The same flush the Quit item does: settings are written on a short delay, and
            // terminating inside that window drops the change.
            appState.flushToDisk()
            NSApplication.shared.terminate(nil)
        case nil:
            break
        }
    }

    nonisolated static func row(
        release: UpdateChecker.Release,
        phase: UpdateInstaller.Phase,
        refusal: String?,
        canStart: Bool
    ) -> Row {
        let version = "Version \(release.version)"

        switch phase {
        case .downloading(let fraction):
            // A percentage when the release said how big the image is, the version when it did
            // not — rather than "0%" for the whole download.
            let progress = fraction.map { "\(Int((min(max($0, 0), 1)) * 100))%" }
            return Row(title: "Downloading update…", subtitle: progress ?? version,
                       symbol: "arrow.down.circle", action: nil)
        case .verifying:
            return Row(title: "Checking the download…", subtitle: version,
                       symbol: "arrow.down.circle", action: nil)
        case .installing:
            return Row(title: "Installing…", subtitle: version,
                       symbol: "arrow.down.circle", action: nil)
        case .restarting:
            return Row(title: "Restarting…", subtitle: version,
                       symbol: "arrow.down.circle", action: nil)
        case .installedNeedsRestart:
            return Row(title: "Quit to finish updating", subtitle: "\(version) is installed",
                       symbol: "arrow.clockwise", action: .quit)
        case .idle, .failed:
            // A build that cannot install — ad-hoc signed, or a release with no disk image — still
            // gets told there is something newer, and the Home banner says why it cannot be pressed
            // here and still has the release notes.
            guard release.dmg != nil, refusal == nil else {
                return Row(title: "\(version) is available", subtitle: "This copy can't update itself — see Home",
                           symbol: "arrow.down.circle", action: .openHome)
            }

            if case .failed = phase {
                return Row(title: "Download and update OurWhisper", subtitle: "Last try failed. Press to try again.",
                           symbol: "exclamationmark.triangle", action: canStart ? .install : nil)
            }
            return Row(title: "Download and update OurWhisper", subtitle: "\(version) is available",
                       symbol: "arrow.down.circle", action: canStart ? .install : nil)
        }
    }
}
