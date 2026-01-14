//
//  LockButton.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct LockButton: View {
    let bbVehicle: BBVehicle
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    var isLocked: Bool {
        guard bbVehicle.modelContext != nil else {
            print(
                "⚠️ [LockButton] BBVehicle \(bbVehicle.vin) is detached from context",
            )
            return false
        }
        return bbVehicle.lockStatus == .locked
    }

    var body: some View {
        let unlock = MainVehicleAction(
            action: { statusUpdater in
                try await setLock(false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "lock.fill"),
            label: "Unlock",
            inProgressLabel: "Unlocking",
            completedText: "Unlocked",
            color: .red,
            menuIcon: Image(systemName: "lock.open.fill")
        )
        let lock = MainVehicleAction(
            action: { statusUpdater in
                try await setLock(true, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "lock.open.fill"),
            label: "Lock",
            inProgressLabel: "Locking",
            completedText: "Locked",
            color: .green,
            menuIcon: Image(systemName: "lock.fill")
        )

        VehicleControlButton(
            actions: [unlock, lock],
            currentActionDeterminant: { isLocked ? unlock : lock },
            transition: transition,
            bbVehicle: bbVehicle,
        )
    }

    @MainActor
    private func setLock(
        _ shouldLock: Bool,
        statusUpdater: @escaping @Sendable (String) -> Void,
    ) async throws {
        guard let account = bbVehicle.account else {
            throw APIError(message: "Account not found for vehicle")
        }

        let context = modelContext

        if shouldLock {
            try await account.lockVehicle(bbVehicle, modelContext: context)
        } else {
            try await account.unlockVehicle(bbVehicle, modelContext: context)
        }

        let targetLockStatus: VehicleStatus.LockStatus =
            shouldLock ? .locked : .unlocked
        try await bbVehicle.waitForStatusChange(
            modelContext: context,
            condition: { status in
                status.lockStatus == targetLockStatus
            },
            statusMessageUpdater: statusUpdater,
        )
    }
}
