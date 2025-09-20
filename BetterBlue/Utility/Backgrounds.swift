//
//  Backgrounds.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/19/25.
//

import SwiftUI

extension BBVehicle {
    struct BackgroundOption {
        let name: String
        let displayName: String
        let gradient: [Color]
    }

    static let availableBackgrounds: [BackgroundOption] = [
        BackgroundOption(
            name: "default",
            displayName: "Default",
            gradient: [
                Color(red: 0.93, green: 0.93, blue: 0.93),
                Color(red: 0.97, green: 0.97, blue: 0.97)
            ],
        ),
        BackgroundOption(
            name: "black",
            displayName: "Black",
            gradient: [
                Color(red: 0.2, green: 0.2, blue: 0.2),
                Color(red: 0.4, green: 0.4, blue: 0.4)
            ],
        ),
        BackgroundOption(
            name: "gray",
            displayName: "Gray",
            gradient: [
                Color(red: 0.6, green: 0.6, blue: 0.6),
                Color(red: 0.75, green: 0.75, blue: 0.75)
            ],
        ),
        BackgroundOption(
            name: "silver",
            displayName: "Silver",
            gradient: [
                Color(red: 0.75, green: 0.75, blue: 0.75),
                Color(red: 0.9, green: 0.9, blue: 0.9)
            ],
        ),
        BackgroundOption(
            name: "darkBlue",
            displayName: "Dark Blue",
            gradient: [
                Color(red: 0.2, green: 0.3, blue: 0.7),
                Color(red: 0.4, green: 0.5, blue: 0.8)
            ],
        ),
        BackgroundOption(
            name: "lightBlue",
            displayName: "Light Blue",
            gradient: [
                Color(red: 0.6, green: 0.8, blue: 1.0),
                Color(red: 0.8, green: 0.9, blue: 1.0)
            ],
        ),
        BackgroundOption(
            name: "darkGreen",
            displayName: "Dark Green",
            gradient: [
                Color(red: 0.2, green: 0.7, blue: 0.3),
                Color(red: 0.4, green: 0.8, blue: 0.5)
            ],
        ),
        BackgroundOption(
            name: "red",
            displayName: "Red",
            gradient: [
                Color(red: 0.8, green: 0.2, blue: 0.2),
                Color(red: 0.9, green: 0.4, blue: 0.4)
            ],
        ),
        BackgroundOption(
            name: "white",
            displayName: "White",
            gradient: [
                Color(red: 0.95, green: 0.95, blue: 0.95),
                Color(red: 0.98, green: 0.98, blue: 0.98)
            ],
        )
    ]

    static let availableWatchBackgrounds: [BackgroundOption] = [
        BackgroundOption(
            name: "charcoal",
            displayName: "Charcoal",
            gradient: [
                Color(red: 0.1, green: 0.1, blue: 0.1),
                Color(red: 0.2, green: 0.2, blue: 0.2)
            ],
        ),
        BackgroundOption(
            name: "deepBlue",
            displayName: "Deep Blue",
            gradient: [
                Color(red: 0.05, green: 0.1, blue: 0.3),
                Color(red: 0.1, green: 0.2, blue: 0.4)
            ],
        ),
        BackgroundOption(
            name: "midnightBlue",
            displayName: "Midnight Blue",
            gradient: [
                Color(red: 0.02, green: 0.05, blue: 0.2),
                Color(red: 0.05, green: 0.1, blue: 0.3)
            ],
        ),
        BackgroundOption(
            name: "forestGreen",
            displayName: "Forest Green",
            gradient: [
                Color(red: 0.05, green: 0.2, blue: 0.1),
                Color(red: 0.1, green: 0.3, blue: 0.15)
            ],
        ),
        BackgroundOption(
            name: "deepPurple",
            displayName: "Deep Purple",
            gradient: [
                Color(red: 0.15, green: 0.05, blue: 0.2),
                Color(red: 0.25, green: 0.1, blue: 0.3)
            ],
        ),
        BackgroundOption(
            name: "darkBrown",
            displayName: "Dark Brown",
            gradient: [
                Color(red: 0.15, green: 0.1, blue: 0.05),
                Color(red: 0.25, green: 0.15, blue: 0.1)
            ],
        ),
        BackgroundOption(
            name: "slate",
            displayName: "Slate",
            gradient: [
                Color(red: 0.1, green: 0.12, blue: 0.15),
                Color(red: 0.15, green: 0.18, blue: 0.22)
            ],
        ),
        BackgroundOption(
            name: "darkRed",
            displayName: "Dark Red",
            gradient: [
                Color(red: 0.2, green: 0.05, blue: 0.05),
                Color(red: 0.3, green: 0.1, blue: 0.1)
            ],
        )
    ]

    var backgroundGradient: [Color] {
        guard let background = Self.availableBackgrounds.first(where: {
            $0.name == backgroundColorName
        }) else {
            return Self.availableBackgrounds[0].gradient
        }
        return background.gradient
    }

    var watchBackgroundGradient: [Color] {
        guard let background = Self.availableWatchBackgrounds.first(where: {
            $0.name == watchBackgroundColorName
        }) else {
            return Self.availableWatchBackgrounds[0].gradient
        }
        return background.gradient
    }
}
