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

struct MainVehicleAction: VehicleAction {
    var action: VehicleButtonAction
    var icon: Image // Icon showing current state when this is the primary action
    var label: String // Action label (e.g., "Unlock")
    var inProgressLabel: String
    var completedText: String
    var color: Color // Color for the state icon
    var stateLabel: String // Label showing current state (e.g., "Locked")
    var shouldPulse: Bool = false
    var shouldRotate: Bool = false
}
