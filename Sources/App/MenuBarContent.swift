import SwiftUI

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !appState.permissions.allGranted {
                Button("Finish setup…") { showWindow(.home) }
                Divider()
            }

            if let release = appState.availableUpdate {
                UpdateMenuItem(
                    release: release,
                    phase: appState.installer.phase,
                    refusal: appState.installer.refusal,
                    openHome: { showWindow(.home) }
                )
                Divider()
            }

            Text(statusLine)

            Divider()

            // Switching mode is the one setting people change mid-task, so it is here rather than
            // two clicks away in the window.
            Menu("Mode") {
                ForEach(appState.modes.modes) { mode in
                    Button {
                        appState.settings.settings.refinement.activeModeID = mode.id
                        appState.settings.settings.refinement.autoSwitchByApp = false
                    } label: {
                        if mode.id == appState.settings.settings.refinement.activeModeID {
                            Label(mode.name, systemImage: "checkmark")
                        } else {
                            Text(mode.name)
                        }
                    }
                }
                Divider()
                Toggle("Switch by app", isOn: autoSwitchBinding)
            }

            Divider()

            Button("Settings…") { showWindow(.configuration) }
                .keyboardShortcut(",", modifiers: .command)
            Button("Modes") { showWindow(.modes) }
            Button("History") { showWindow(.history) }

            Divider()

            Button("Quit OurWhisper") {
                // Settings are written on a short delay to survive a burst of typing. Quitting
                // inside that window would otherwise drop the change the user just made.
                appState.flushToDisk()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var autoSwitchBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.settings.refinement.autoSwitchByApp },
            set: { appState.settings.settings.refinement.autoSwitchByApp = $0 }
        )
    }

    private var statusLine: String {
        switch appState.recordingState {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .formatting: "Cleaning up…"
        case .failed(let message): "Error: \(message)"
        }
    }

    private func showWindow(_ section: NavigationSection) {
        appState.selectedSection = section
        WindowPresenter.activate()
        openWindow(id: WindowID.main)
    }
}
