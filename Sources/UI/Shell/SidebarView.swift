import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationSection

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // One `Section` per group. The whitespace between groups is the section break
                // itself: padding a section pads every row inside it instead, which left the four
                // rows below the first group 10pt taller than the three above them.
                ForEach(NavigationSection.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { section in
                            // An explicit HStack rather than `Label`. In a sidebar list, `Label`
                            // puts its icon in the list's icon gutter, and macOS 26's floating
                            // sidebar clips that gutter — the tinted squares end up sliced off
                            // against the window edge.
                            HStack(spacing: 8) {
                                SectionIcon(symbol: section.symbol, tint: section.tint)
                                Text(section.title)
                                    .font(.system(size: 14))
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .tag(section)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            SidebarFooter()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }
}

private struct SidebarFooter: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://github.com/grozoww/our-whisper")!) {
                Text("OurWhisper")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: .capsule)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
