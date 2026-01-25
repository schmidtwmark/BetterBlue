//
//  VehicleButtonAction.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/5/25.
//

import Foundation
import SwiftUI

typealias VehicleButtonAction = @Sendable (@escaping @Sendable (String) -> Void) async throws -> Void

protocol VehicleAction {
    var action: VehicleButtonAction { get }
    var icon: Image { get }
    var label: String { get }
    var inProgressLabel: String { get }
}

struct MenuVehicleAction: VehicleAction {
    var action: VehicleButtonAction
    var icon: Image
    var label: String
    var inProgressLabel: String

    init(action: @escaping VehicleButtonAction, icon: Image, label: String, inProgressLabel: String = "") {
        self.action = action
        self.icon = icon
        self.label = label
        self.inProgressLabel = inProgressLabel
    }
}

struct MainVehicleAction: VehicleAction {
    var action: VehicleButtonAction
    var icon: Image // Icon showing current state when this is the primary action
    var label: String // Action label (e.g., "Unlock")
    var inProgressLabel: String
    var completedText: String
    var color: Color // Color for the state icon
    var stateLabel: String // Label showing current state (e.g., "Locked")
    var quickActionColor: Color = .accentColor // Color for the quick action button icon
    var additionalText: String = ""
    var shouldPulse: Bool = false
    var shouldRotate: Bool = false
    var menuIcon: Image? // Alternative icon for menu items and quick action button
}
