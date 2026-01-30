//
//  MainViewRefresh.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Vehicle Refresh Extension

extension MainView {
    /// Refresh the current vehicle's status if it's older than 5 minutes
    func refreshCurrentVehicleIfNeeded(modelContext: ModelContext) async {
        guard let vehicle = currentVehicle else { return }

        // Don't auto-refresh if the last response was an error (to avoid retry loops)
        if lastError != nil {
            BBLogger.info(.app, "MainView: Last response was an error, skipping auto-refresh")
            return
        }

        // Check if status is older than 5 minutes
        if let lastUpdated = vehicle.lastUpdated,
           lastUpdated > Date().addingTimeInterval(-300) {
            BBLogger.info(.app, "MainView: Vehicle \(vehicle.displayName) status is fresh, skipping refresh")
            return
        }

        BBLogger.info(.app, "MainView: Refreshing status for selected vehicle: \(vehicle.displayName)")

        do {
            if let account = vehicle.account {
                let status = try await account.fetchVehicleStatus(
                    for: vehicle,
                    modelContext: modelContext
                )
                vehicle.updateStatus(with: status)

                await MainActor.run {
                    WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
                }

                BBLogger.info(.app, "MainView: Successfully refreshed \(vehicle.displayName)")
            }
        } catch {
            BBLogger.error(.app, "MainView: Failed to refresh vehicle \(vehicle.displayName): \(error)")
        }
    }
}
