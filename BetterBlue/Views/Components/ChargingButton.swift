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
            BBLogger.warning(.app, "ChargingButton: BBVehicle \(bbVehicle.vin) is detached from context")
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

    var notChargingStateLabel: String {
        if isPluggedIn {
            "Ready to Charge"
        } else {
            "Unplugged"
        }
    }

    var body: some View {
        PersistentModelGuard(model: bbVehicle) {
            activeBody
        }
    }

    @ViewBuilder
    private var activeBody: some View {
        // User-customizable charging color drives the bolt icon, the
        // "ready to charge" plugged-in state, and the actively-charging
        // status icon. Stays grey when unplugged so the disabled state
        // still reads correctly regardless of palette.
        let chargingColor = bbVehicle.chargingColor

        let startCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(true, statusUpdater: statusUpdater)
            },
            icon: plugIcon,
            label: "Start Charge",
            inProgressLabel: "Starting Charge",
            completedText: "Charging started",
            color: isPluggedIn ? chargingColor : .secondary,
            stateLabel: notChargingStateLabel,
            quickActionColor: chargingColor,
            menuIcon: Image(systemName: "bolt.fill")
        )
        let stopCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "bolt.fill"),
            label: "Stop Charge",
            inProgressLabel: "Stopping Charge",
            completedText: "Charge stopped",
            color: chargingColor,
            stateLabel: "Charging",
            quickActionColor: .secondary,
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
                try await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle,
                    modelContext: context,
                    cached: false
                )
            } catch {
                BBLogger.warning(.app, "ChargingButton: Failed to fetch status after stop command: \(error)")
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
