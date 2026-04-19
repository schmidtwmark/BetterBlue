//
//  TroubleshootingView.swift
//  BetterBlue
//
//  In-app rendering of the shared troubleshooting document. Content
//  comes from `TroubleshootingDocument.markdown` (BetterBlueKit), which
//  reads the bundled `Troubleshooting.md` — the same file that's linked
//  to at the repo root. Never hard-code copy here; update the markdown
//  file instead.
//

import BetterBlueKit
import SwiftUI

struct TroubleshootingView: View {
    /// Optional override of document-order. Pass section titles to pin
    /// them to the top in the order given (unknown titles are ignored;
    /// remaining sections fall through in document order). Used on the
    /// Watch context to put Apple Watch Syncing first.
    let orderedTitles: [String]

    init(orderedTitles: [String] = []) {
        self.orderedTitles = orderedTitles
    }

    private var sections: [TroubleshootingDocument.Section] {
        guard !orderedTitles.isEmpty else { return TroubleshootingDocument.sections }

        let all = TroubleshootingDocument.sections
        var byTitle = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0) })
        var ordered: [TroubleshootingDocument.Section] = []

        for title in orderedTitles {
            if let section = byTitle.removeValue(forKey: title) {
                ordered.append(section)
            }
        }
        // Preserve original order for the remaining, unpinned sections.
        for section in all where byTitle[section.title] != nil {
            ordered.append(section)
        }
        return ordered
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                TroubleshootingDisclosureSection(section: section)
            }

            Section {
                Link(destination: URL(string: "https://github.com/schmidtwmark/BetterBlue/issues")!) {
                    Label("Report an Issue on GitHub", systemImage: "exclamationmark.bubble")
                }
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One collapsible section, rendered as a headerless `Section` whose
/// first row is a tappable title + chevron and whose body is revealed
/// on expand. This reads more like a FAQ than the default
/// `DisclosureGroup` inset look, which the designer wanted: users scan
/// titles and tap whichever they want to open.
///
/// All sections start collapsed so nothing steals focus on first open.
private struct TroubleshootingDisclosureSection: View {
    let section: TroubleshootingDocument.Section
    @State private var isExpanded: Bool = false

    var body: some View {
        Section {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                TroubleshootingMarkdownBody(raw: section.body)
                    .font(.callout)
                    .tint(.blue)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// Renders the body of one section. `AttributedString(markdown:)`
/// collapses blank-line paragraph breaks, so we split on them and render
/// each block as its own Text.
struct TroubleshootingMarkdownBody: View {
    let raw: String

    var body: some View {
        let blocks = raw.components(separatedBy: "\n\n")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let attributed = try? AttributedString(
                        markdown: trimmed,
                        options: .init(
                            interpretedSyntax: .inlineOnlyPreservingWhitespace
                        )
                    ) {
                        Text(attributed)
                            .foregroundStyle(.primary)
                    } else {
                        Text(trimmed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NavigationStack {
        TroubleshootingView()
    }
}
