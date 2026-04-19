//
//  WatchTroubleshootingView.swift
//  BetterBlueWatch Watch App
//
//  Watch-sized renderer for the shared troubleshooting document. Source
//  text comes from `TroubleshootingDocument.markdown` (BetterBlueKit);
//  never hard-code copy here.
//

import BetterBlueKit
import SwiftUI

struct WatchTroubleshootingView: View {
    /// On the Watch, surface the sync guidance first — it's the most
    /// common reason a user taps Troubleshooting here. Section titles
    /// must match the markdown `## Heading` exactly.
    private static let watchSectionOrder = [
        "Apple Watch Syncing",
        "Resolving Login Issues",
        "Widget Issues",
        "Supported Regions"
    ]

    private var sections: [TroubleshootingDocument.Section] {
        let all = TroubleshootingDocument.sections
        var byTitle = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0) })
        var ordered: [TroubleshootingDocument.Section] = []
        for title in Self.watchSectionOrder {
            if let section = byTitle.removeValue(forKey: title) {
                ordered.append(section)
            }
        }
        for section in all where byTitle[section.title] != nil {
            ordered.append(section)
        }
        return ordered
    }

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                WatchTroubleshootingDisclosure(
                    section: section,
                    initiallyExpanded: index == 0
                )
            }
        }
        .navigationTitle("Help")
    }
}

/// Watch-sized collapsible section. `DisclosureGroup` isn't available on
/// watchOS, so this is a hand-rolled Button + chevron + conditional body.
/// First section starts expanded.
private struct WatchTroubleshootingDisclosure: View {
    let section: TroubleshootingDocument.Section
    let initiallyExpanded: Bool
    @State private var isExpanded: Bool

    init(section: TroubleshootingDocument.Section, initiallyExpanded: Bool) {
        self.section = section
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(section.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                WatchTroubleshootingBody(raw: section.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchTroubleshootingBody: View {
    let raw: String

    var body: some View {
        let blocks = raw.components(separatedBy: "\n\n")
        VStack(alignment: .leading, spacing: 6) {
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
                    } else {
                        Text(trimmed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
