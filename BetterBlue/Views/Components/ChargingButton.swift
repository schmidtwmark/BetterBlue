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

    var additionalText: String {
        if isCharging, let evStatus, evStatus.chargeSpeed > 0 {
            return String(format: "%.1f kW", evStatus.chargeSpeed)
        }
        return ""
    }

    var body: some View {
        let startCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(true, statusUpdater: statusUpdater)
            },
            icon: "bolt.slash",
            label: "Start Charge",
            inProgressLabel: "Starting Charge",
            completedText: "Charging started",
            color: .gray,
        )
        let stopCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(false, statusUpdater: statusUpdater)
            },
            icon: "bolt.fill",
            label: "Stop Charge",
            inProgressLabel: "Stopping Charge",
            completedText: "Charge stopped",
            color: .green,
            additionalText: additionalText,
            shouldPulse: true,
        )

        VehicleControlButton(
            actions: [startCharging, stopCharging],
            currentActionDeterminant: { isCharging ? stopCharging : startCharging },
            transition: transition,
            bbVehicle: bbVehicle,
        )
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
