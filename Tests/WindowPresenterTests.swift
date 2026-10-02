import AppKit
import Testing

@testable import OurWhisper

/// Which window the app is allowed to order front.
///
/// `NSApp.windows` contains AppKit's own windows alongside the app's: the status item lives in an
/// `NSStatusBarWindow`, and a menu that has been opened once leaves an `NSPopupMenuWindow` behind
/// it. Neither is an `NSPanel`, so the obvious "every window that is not a panel" filter picks
/// both up — and ordering the dismissed menu's window front paints an empty rounded rectangle
/// next to the menu bar that stays there until the app quits. Those two classes cannot be built
/// in a test, so the stand-ins below copy what separates them from a real window: they float
/// above the ordinary window level.
@Suite("Window presenter", .serialized)
@MainActor
struct WindowPresenterTests {
    private func makeWindow(level: NSWindow.Level = .normal, identifier: String? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // A programmatically created window releases itself on close, which ARC then releases
        // again — see `ViewRenderingTests`.
        window.isReleasedWhenClosed = false
        window.level = level
        window.identifier = identifier.map(NSUserInterfaceItemIdentifier.init(rawValue:))
        return window
    }

    @Test("Picks the scene's window, not AppKit's")
    func picksTheSceneWindow() {
        let statusItem = makeWindow(level: .statusBar)
        let dismissedMenu = makeWindow(level: .popUpMenu)
        let scene = makeWindow(identifier: WindowID.main)

        // Ordered so that a naive "first window that is not a panel" would find the wrong one.
        let found = WindowPresenter.mainWindow(among: [statusItem, dismissedMenu, scene])

        #expect(found === scene)
    }

    @Test("Falls back to the first ordinary window")
    func fallsBackToAnOrdinaryWindow() {
        let statusItem = makeWindow(level: .statusBar)
        // SwiftUI sets the identifier from the scene id, but nothing in the framework promises to
        // keep doing so; without a fallback a change there would stop the window coming forward.
        let scene = makeWindow()

        #expect(WindowPresenter.mainWindow(among: [statusItem, scene]) === scene)
    }

    @Test("Finds nothing when only AppKit's windows are open")
    func ignoresAppKitOnlyWindows() {
        let statusItem = makeWindow(level: .statusBar)
        let dismissedMenu = makeWindow(level: .popUpMenu)

        #expect(WindowPresenter.mainWindow(among: [statusItem, dismissedMenu]) == nil)
    }

    @Test("The window comes to the user's desktop instead of taking them to its own")
    func followsToTheCurrentDesktop() {
        // The scene's window is created at launch, on whichever desktop the app started on.
        // Without this, opening it from the menu bar anywhere else slid the user back there.
        let scene = makeWindow(identifier: WindowID.main)
        scene.collectionBehavior = [.fullScreenPrimary]

        WindowPresenter.followsToCurrentDesktop(scene)

        #expect(scene.collectionBehavior.contains(.moveToActiveSpace))
        // Added to, not replaced: full screen has to keep working.
        #expect(scene.collectionBehavior.contains(.fullScreenPrimary))
    }
}
