//
//  CustomColors.swift
//  BetterBlue
//
//  Catalog of named color choices users can pick from to customize
//  per-vehicle UI accents (refresh button, map pin, lock state,
//  climate action, charging bolt).
//
//  Colors are persisted by name so the SwiftData store doesn't have
//  to round-trip raw `Color`s (which aren't directly Codable). The
//  resolver (`color(forName:default:)`) maps a stored name back to a
//  SwiftUI `Color`; unknown names fall through to the default so a
//  future renamed/removed option doesn't crash.
//

import SwiftUI

enum CustomColor {
    struct Option: Identifiable, Hashable {
        let name: String
        let displayName: String
        let color: Color

        var id: String { name }

        static func == (lhs: Option, rhs: Option) -> Bool { lhs.name == rhs.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    static let palette: [Option] = [
        Option(name: "blue",    displayName: "Blue",    color: .blue),
        Option(name: "green",   displayName: "Green",   color: .green),
        Option(name: "red",     displayName: "Red",     color: .red),
        Option(name: "orange",  displayName: "Orange",  color: .orange),
        Option(name: "yellow",  displayName: "Yellow",  color: .yellow),
        Option(name: "pink",    displayName: "Pink",    color: .pink),
        Option(name: "purple",  displayName: "Purple",  color: .purple),
        Option(name: "indigo",  displayName: "Indigo",  color: .indigo),
        Option(name: "teal",    displayName: "Teal",    color: .teal),
        Option(name: "cyan",    displayName: "Cyan",    color: .cyan),
        Option(name: "mint",    displayName: "Mint",    color: .mint),
        Option(name: "brown",   displayName: "Brown",   color: .brown),
        Option(name: "gray",    displayName: "Gray",    color: .gray),
    ]

    /// Look up a `Color` for a stored name, falling back to the named
    /// default if the value is missing or unrecognized.
    static func color(forName name: String?, default defaultName: String) -> Color {
        if let name, let match = palette.first(where: { $0.name == name }) {
            return match.color
        }
        return palette.first { $0.name == defaultName }?.color ?? .blue
    }

    /// Resolve a name to a palette `Option`, falling back to the named
    /// default. Used by the picker UI to render the currently-selected
    /// swatch.
    static func option(forName name: String?, default defaultName: String) -> Option {
        if let name, let match = palette.first(where: { $0.name == name }) {
            return match
        }
        return palette.first { $0.name == defaultName } ?? palette[0]
    }
}
