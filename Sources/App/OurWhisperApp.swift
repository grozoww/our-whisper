import SwiftUI

@main
struct OurWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("OurWhisper", id: WindowID.main) {
            RootView()
                .environment(appState)
                .task {
                    AppStateHolder.shared = appState
                    if ScreenshotMode.isActive {
                        await ScreenshotMode.run(appState: appState)
                    } else {
                        await appState.start()
                    }
                }
        }
        .defaultSize(width: 940, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            MenuBarLabel(state: appState.recordingState, updateAvailable: appState.availableUpdate != nil)
        }
    }
}

/// The glyph beside the clock.
///
/// A view rather than an inline `Image` because the idle glyph comes out of the asset catalog and
/// the busy ones are SF Symbols, and a `switch` needs somewhere to live. The frog is left at its
/// natural 18 points: `MenuBarExtra` hands the label straight to the status item, which does not
/// resize it, and `.resizable()` here would stretch a template to whatever the bar allowed.
struct MenuBarLabel: View {
    let state: AppState.RecordingState
    let updateAvailable: Bool

    var body: some View {
        Group {
            switch state.menuBarGlyph(updateAvailable: updateAvailable) {
            case .asset(let name): Image(name)
            case .symbol(let name): Image(systemName: name)
            }
        }
        .accessibilityLabel(state.accessibilityLabel(updateAvailable: updateAvailable))
    }
}

enum WindowID {
    static let main = "main"
}

/// The app is an `LSUIElement` accessory: no Dock icon, and it never steals focus on its own.
/// That matters more than it sounds — the whole product depends on another app keeping keyboard
/// focus while we record. Windows are shown only on explicit user action, and only then do we
/// briefly become a regular app so the window can come forward and accept input.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Last chance to write coalesced settings, modes, vocabulary and history to disk. Without
    /// this, a change made in the last fraction of a second before quitting is lost.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppStateHolder.shared?.flushToDisk() }
    }
}

/// A weak pointer to the live `AppState`, so the app delegate can reach it on the way out.
///
/// The delegate is created by SwiftUI before the scene exists and receives no reference to it, and
/// `applicationWillTerminate` is the only place a final flush can happen.
@MainActor
enum AppStateHolder {
    static weak var shared: AppState?
}

@MainActor
enum WindowPresenter {
    /// Set by the Dock preference. When on, the app stays a regular app and never drops back to
    /// accessory, so the Dock icon does not blink out every time the window closes.
    static var showsDockIcon = false

    /// Bring a window forward from an accessory app. `openWindow` alone is not enough: an
    /// accessory app is not in the activation order, so the window would appear behind whatever
    /// the user was using.
    ///
    /// The policy is left alone when the Dock icon is off. Switching to `.regular` here is what
    /// put the app in the Dock for as long as its window was open, whatever the toggle in
    /// Configuration said — and the toggle then read as broken rather than as the preference it
    /// is. An accessory app can hold a key window and take keyboard input perfectly well; it just
    /// has to be told to activate, which is the line below.
    static func activate() {
        let window = mainWindow(among: NSApp.windows)
        // Before activating, because activating is what moves the user. See
        // `followsToCurrentDesktop`.
        window.map(followsToCurrentDesktop)

        if showsDockIcon { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)

        // Ordering the window front explicitly matters on first launch: the scene exists from
        // launch, but an accessory app's window is not in the activation order, so without this
        // the app appears not to have started at all.
        window?.makeKeyAndOrderFront(nil)
    }

    /// Makes the window come to the desktop the user is on, rather than the user go to the window.
    ///
    /// An ordinary window belongs to the desktop it was created on, and the scene's window is
    /// created at launch — so it lived on whichever desktop the app happened to start on, and
    /// opening it from the menu bar on any other desktop slid the user back there. Measured on
    /// macOS 26: without this, activating the app and ordering its window front switched desktops
    /// every time; with it, the window moved instead.
    static func followsToCurrentDesktop(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    /// Drop back to accessory once the last window closes, so we leave the Dock and the
    /// command-tab list again.
    static func resignIfNoWindows() {
        guard !showsDockIcon else { return }
        guard mainWindow(among: NSApp.windows)?.isVisible != true else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// The app's own window, picked out of everything AppKit keeps in `NSApp.windows`.
    ///
    /// That list is not only ours. It also holds the status item's window and — once the menu bar
    /// menu has been opened even once — the backing window of the dismissed menu, and both are
    /// plain `NSWindow`s, so skipping panels does not skip them. Ordering the menu's window front
    /// is what left a blank rounded rectangle sitting beside the menu bar after every visit to
    /// Settings, and counting the status item's window as "still open" is why the app never went
    /// back to being an accessory. Both of them float above the ordinary window level, which is
    /// what the fallback matches on; the scene's window sits at `.normal` and carries the scene
    /// id with it.
    static func mainWindow(among windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == WindowID.main }
            ?? windows.first { !($0 is NSPanel) && $0.level == .normal }
    }

    static func setShowsDockIcon(_ shows: Bool) {
        showsDockIcon = shows
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        if shows { NSApp.activate(ignoringOtherApps: false) }
    }
}
