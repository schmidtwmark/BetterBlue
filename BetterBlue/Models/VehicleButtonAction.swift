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
    var icon: String { get }
    var label: String { get }
    var inProgressLabel: String { get }
}

struct MenuVehicleAction: VehicleAction {
    var action: VehicleButtonAction
    var icon: String
    var label: String
    var inProgressLabel: String

    init(action: @escaping VehicleButtonAction, icon: String, label: String, inProgressLabel: String = "") {
        self.action = action
        self.icon = icon
        self.label = label
        self.inProgressLabel = inProgressLabel
    }
}

struct MainVehicleAction: VehicleAction {
    var action: VehicleButtonAction
    var icon: String
    var label: String
    var inProgressLabel: String
    var completedText: String
    var color: Color
    var additionalText: String = ""
    var shouldPulse: Bool = false
    var shouldRotate: Bool = false
    var menuIcon: String? // Optional alternative icon for menu items
}
