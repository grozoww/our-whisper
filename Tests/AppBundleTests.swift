import AppKit
import ServiceManagement
import Testing

@testable import OurWhisper

/// How the app presents itself to macOS, rather than what it does with a recording.
///
/// Everything covered here fails silently. A missing app icon compiles, links, packages and
/// installs, and is only noticed by whoever looks in the Dock. A login item that cannot register
/// says nothing at all — the app simply does not come back after a restart. And a permission reset
/// aimed at the wrong identifier reports success while fixing nothing.
@Suite("App bundle")
struct AppBundleTests {
    /// The tests run against the app as their host, so `Bundle.main` is the real app bundle. That
    /// is what makes this checkable at all: it is the shipped bundle being inspected, not a
    /// fixture.
    @Test("The app bundle carries an icon")
    func hasAppIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
        // Present in the compiled asset catalog, not merely named in Info.plist. Deleting
        // Sources/Resources/Assets.xcassets leaves the key behind and the icon gone.
        #expect(NSImage(named: "AppIcon") != nil)
    }

    /// The menu bar glyph fails quieter still than the app icon: an unresolved name draws nothing
    /// at all, and the app's only visible surface becomes an empty gap beside the clock. The
    /// template flag is the other half — without it macOS ships the artwork as literal black
    /// pixels, which are invisible on a dark menu bar.
    @Test("The menu bar carries the app's own mark, as a template")
    func hasMenuBarIcon() throws {
        let icon = try #require(NSImage(named: AppState.MenuBarGlyph.frog))
        #expect(icon.isTemplate)
        // 18 points is what a status item is given. `MenuBarExtra` does not resize the label, so
        // artwork of any other size arrives at that size.
        #expect(icon.size == CGSize(width: 18, height: 18))
    }

    /// The frog with the download badge is a second image, and fails the same quiet way as the
    /// first: an unresolved name or a lost template flag, and the one moment the icon is meant to
    /// catch the eye is the moment it vanishes.
    @Test("The glyph shown for a waiting update is a template of the same size")
    func hasUpdateIcon() throws {
        let icon = try #require(NSImage(named: AppState.MenuBarGlyph.frogWithUpdate))
        #expect(icon.isTemplate)
        // Swapped in for the frog, so it must not make the status item grow or shrink.
        #expect(icon.size == CGSize(width: 18, height: 18))
    }

    @Test("Every login-item state explains itself", arguments: [
        SMAppService.Status.enabled,
        .requiresApproval,
        .notFound,
        .notRegistered,
    ])
    func loginItemStatesExplainThemselves(status: SMAppService.Status) {
        let explanation = LaunchAtLogin.explanation(for: status)
        #expect(!explanation.isEmpty)
        // CLAUDE.md's rule for user-facing strings: say what to do about it. A status code echoed
        // back at the user is the failure this guards against.
        #expect(!explanation.contains("requiresApproval"))
        #expect(!explanation.contains("notRegistered"))
    }

    /// Reads the live state. Never registers: the test host is a build in DerivedData, and
    /// registering it would add a login item on the machine running the suite that points at a
    /// directory Xcode will eventually delete.
    @Test("Reading the login-item status is side-effect free")
    func readingStatusDoesNotRegister() {
        let before = LaunchAtLogin.status
        #expect(LaunchAtLogin.isEnabled == (before == .enabled))
        #expect(LaunchAtLogin.status == before)
    }

    /// Inspected, never run. Running it would clear the Accessibility grant of whoever ran the
    /// suite — and because the app is its own test host, the bundle it would clear is the real
    /// one. What is worth pinning down is the target: an identifier that is empty, stale or
    /// belonging to something else makes `tccutil` report success having fixed nothing, which is
    /// indistinguishable to the user from the bug the button exists to fix.
    @Test("The Accessibility reset targets this app and nothing else")
    @MainActor
    func accessibilityResetTargetsThisApp() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let command = try #require(PermissionsManager().accessibilityResetCommand)

        #expect(command.path == "/usr/bin/tccutil")
        #expect(command.arguments == ["reset", "Accessibility", identifier])
    }
}
