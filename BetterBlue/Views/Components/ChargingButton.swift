//
//  ChargingButton.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct ChargingButton: View {
    let bbVehicle: BBVehicle
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var showingChargeLimitSettings = false

    var evStatus: VehicleStatus.EVStatus? {
        guard bbVehicle.modelContext != nil else {
            print(
                "⚠️ [ChargingButton] BBVehicle \(bbVehicle.vin) is detached from context",
            )
            return nil
        }
        return bbVehicle.evStatus
    }

    var isCharging: Bool {
        evStatus?.charging ?? false
    }

    var isPluggedIn: Bool {
        evStatus?.pluggedIn ?? false
    }

    nonisolated func showChargeLimitSettings() {
        Task { @MainActor in showingChargeLimitSettings = true }
    }

    var plugIcon: Image {
        bbVehicle.plugIcon(for: evStatus?.plugType)
    }

    var body: some View {
        let startCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(true, statusUpdater: statusUpdater)
            },
            icon: plugIcon,
            label: "Start Charge",
            inProgressLabel: "Starting Charge",
            completedText: "Charging started",
            color: .gray,
            menuIcon: Image(systemName: "bolt.fill")
        )
        let stopCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(false, statusUpdater: statusUpdater)
            },
            icon: plugIcon,
            label: "Stop Charge",
            inProgressLabel: "Stopping Charge",
            completedText: "Charge stopped",
            color: .green,
            shouldPulse: true,
            menuIcon: Image(systemName: "bolt.slash")
        )

        let chargeLimitSettings = MenuVehicleAction(
            action: { _ in showChargeLimitSettings() },
            icon: Image(systemName: "battery.100percent"),
            label: "Charge Limits"
        )

        VehicleControlButton(
            actions: [startCharging, stopCharging, chargeLimitSettings],
            currentActionDeterminant: { isCharging ? stopCharging : startCharging },
            transition: transition,
            bbVehicle: bbVehicle,
        )
        .sheet(isPresented: $showingChargeLimitSettings) {
            ChargeLimitSettingsSheet(vehicle: bbVehicle)
        }
    }

    @MainActor
    private func setCharge(
        _ shouldStart: Bool,
        statusUpdater: @escaping @Sendable (String) -> Void,
    ) async throws {
        guard let account = bbVehicle.account else {
            throw APIError(message: "Account not found for vehicle")
        }

        let context = modelContext

        if shouldStart {
            try await account.startCharge(bbVehicle, modelContext: context)
        } else {
            try await account.stopCharge(bbVehicle, modelContext: context)

            // Immediately fetch status to update Live Activity
            // This ensures the Live Activity ends even if waitForStatusChange times out
            do {
                try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)
            } catch {
                print("⚠️ [ChargingButton] Failed to fetch status after stop command: \(error)")
            }
        }

        try await bbVehicle.waitForStatusChange(
            modelContext: context,
            condition: { status in
                status.evStatus?.charging == shouldStart
            },
            statusMessageUpdater: statusUpdater,
        )
    }
}
