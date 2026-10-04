import SwiftUI

/// Every model the app can use, what it costs in disk, and how to remove it.
struct ModelsLibraryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: "Speech models",
                subtitle: "The offline model is downloaded once and runs on this Mac. The cloud model needs your own API key and sends audio to the provider."
            ) {
                ForEach(Array(appState.models.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowDivider() }
                    ModelEntryRow(entry: entry)
                }
            }

            SettingsSection(
                title: "Cleanup model",
                subtitle: "Rewrites what the speech model heard — filler, punctuation, tone — using each mode's instructions. Downloaded once and runs on this Mac."
            ) {
                ModelEntryRow(entry: appState.models.cleanupEntry)
            }

            SettingsSection(
                title: "Where it lives",
                subtitle: "Nothing is hidden. These are ordinary directories you can open, inspect and delete yourself."
            ) {
                PathRow(
                    title: "Speech model",
                    url: appState.models.parakeetDirectory
                )
                RowDivider()
                PathRow(
                    title: "Cleanup model",
                    url: appState.onDeviceRefiner.fileURL.deletingLastPathComponent()
                )
                RowDivider()
                PathRow(
                    title: "App data",
                    url: AppDirectories.support
                )
            }
        }
        .task { appState.models.refresh() }
    }
}

private struct ModelEntryRow: View {
    @Environment(AppState.self) private var appState
    let entry: ModelLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                symbol: entry.kind == .cloud ? "cloud" : "cpu",
                title: entry.name,
                detail: entry.detail,
                tint: entry.kind == .cloud ? .blue : .green
            ) {
                control
            }

            HStack(spacing: 14) {
                tag(entry.vendor, symbol: "building.2")
                tag(entry.languages, symbol: "globe")
                tag(entry.licence, symbol: "doc.text")
                if case .installed(let bytes) = entry.state {
                    tag(formattedBytes(bytes), symbol: "internaldrive")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 52)
            .padding(.bottom, 14)

            if case .downloading(let fraction) = entry.state {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 52)
                    .padding(.bottom, 14)
            }

            if case .optimizing = entry.state {
                Text("Optimizing for this Mac's Neural Engine. This happens once and can take a few minutes — leave OurWhisper running until it finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 52)
                    .padding(.bottom, 14)
            }

            if case .failed(let message) = entry.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 52)
                    .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch entry.state {
        case .notInstalled:
            Button("Download") { Task { await appState.models.download(entry.id) } }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Try again") { Task { await appState.models.download(entry.id) } }
                .buttonStyle(.borderedProminent)
        case .preparing:
            ProgressView().controlSize(.small)
        case .optimizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                ElapsedClock(since: appState.speechModel.startedAt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        case .installed:
            Button("Remove") { Task { await appState.models.remove(entry.id) } }
                .buttonStyle(.bordered)
        case .ready:
            Label("Key added", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .needsKey:
            Button("Add key…") { appState.selectedSection = .configuration }
                .buttonStyle(.bordered)
        }
    }

    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
    }
}

private struct PathRow: View {
    let title: String
    let url: URL

    var body: some View {
        SettingsRow(
            symbol: "folder",
            title: title,
            detail: url.path(percentEncoded: false)
        ) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.bordered)
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
