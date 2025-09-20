//
//  WatchVehicleView.swift
//  BetterBlueWatch Watch App
//
//  Created by Mark Schmidt on 8/29/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct WatchVehicleView: View {
    let vehicle: BBVehicle
    @State private var appSettings = AppSettings.shared
    @State private var isRefreshing = false
    @State private var lastRefreshDate: Date?
    @State private var showingSettings = false
    @Query private var allVehicles: [BBVehicle]
    @Environment(\.modelContext) private var modelContext

    // Get the latest background info for this vehicle from the query
    private var currentVehicle: BBVehicle {
        allVehicles.first(where: { $0.vin == vehicle.vin }) ?? vehicle
    }

    private var batteryPercentage: Int? {
        guard currentVehicle.isElectric, let evStatus = currentVehicle.evStatus else { return nil }
        return Int(evStatus.evRange.percentage)
    }

    private var fuelPercentage: Int? {
        guard !currentVehicle.isElectric, let gasRange = currentVehicle.gasRange else { return nil }
        return Int(gasRange.percentage)
    }

    private var rangeText: String {
        if currentVehicle.isElectric, let evStatus = currentVehicle.evStatus {
            let range = evStatus.evRange.range.length > 0 ?
                evStatus.evRange.range.units.format(evStatus.evRange.range.length, to: appSettings.preferredDistanceUnit) :
                "--"
            return "\(Int(evStatus.evRange.percentage))% • \(range)"
        } else if let gasRange = currentVehicle.gasRange {
            let range = gasRange.range.length > 0 ?
                gasRange.range.units.format(gasRange.range.length, to: appSettings.preferredDistanceUnit) :
                "--"
            return "\(Int(gasRange.percentage))% • \(range)"
        }
        return "No data"
    }

    private var isLocked: Bool {
        currentVehicle.lockStatus == .locked
    }

    private var isClimateRunning: Bool {
        currentVehicle.climateStatus?.airControlOn ?? false
    }

    private var isPluggedIn: Bool {
        guard currentVehicle.isElectric, let evStatus = currentVehicle.evStatus else { return false }
        return evStatus.pluggedIn
    }

    private var isCharging: Bool {
        guard currentVehicle.isElectric, let evStatus = currentVehicle.evStatus else { return false }
        return evStatus.charging
    }

    // VehicleAction instances
    private var lockAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performLockAction(shouldLock: true, statusUpdater: statusUpdater)
            },
            icon: "lock.fill",
            label: "Lock",
            inProgressLabel: "Locking",
            completedText: "Locked",
            color: .green,
        )
    }

    private var unlockAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performLockAction(shouldLock: false, statusUpdater: statusUpdater)
            },
            icon: "lock.open.fill",
            label: "Unlock",
            inProgressLabel: "Unlocking",
            completedText: "Unlocked",
            color: .red,
        )
    }

    private var startClimateAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performClimateAction(shouldStart: true, statusUpdater: statusUpdater)
            },
            icon: "fan",
            label: "Start Climate",
            inProgressLabel: "Starting",
            completedText: "Started",
            color: .blue,
        )
    }

    private var stopClimateAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performClimateAction(shouldStart: false, statusUpdater: statusUpdater)
            },
            icon: "fan",
            label: "Stop Climate",
            inProgressLabel: "Stopping",
            completedText: "Stopped",
            color: .blue,
            shouldRotate: true,
        )
    }

    private var startChargeAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performChargeAction(shouldStart: true, statusUpdater: statusUpdater)
            },
            icon: "bolt.slash",
            label: "Start Charge",
            inProgressLabel: "Starting",
            completedText: "Charging",
            color: .gray,
        )
    }

    private var stopChargeAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performChargeAction(shouldStart: false, statusUpdater: statusUpdater)
            },
            icon: "bolt.fill",
            label: "Stop Charge",
            inProgressLabel: "Stopping",
            completedText: "Stopped",
            color: .green,
            shouldPulse: true
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                //                // Vehicle name at the top
                VStack {
                    // Status info with inline refresh button
                    HStack(spacing: 4) {
                        Button {
                            showingSettings = true
                        } label: {
                            VStack(spacing: 4) {
                                HStack {
                                    Text(currentVehicle.displayName)
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                HStack {
                                    Image(systemName: currentVehicle.isElectric ? "bolt.fill" : "fuelpump.fill")
                                        .foregroundColor(currentVehicle.isElectric ? .green : .orange)
                                        .font(.caption)

                                    Text(rangeText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                if let lastUpdated = currentVehicle.lastUpdated {
                                    HStack {
                                        Text(formatUpdateTime(lastUpdated))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Inline refresh button
                        Button {
                            Task {
                                await refreshStatus()
                            }
                        } label: {
                            if isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.glass)
                        .frame(width: 30, height: 30)
                        .disabled(isRefreshing)
                    }
                }

                // Context-sensitive action buttons
                VStack(spacing: 8) {
                    // Lock/Unlock button (context-sensitive)
                    WatchVehicleButton(
                        currentAction: isLocked ? unlockAction : lockAction,
                        allActions: [lockAction, unlockAction],
                        menuLabel: "Door Actions",
                        vehicle: vehicle,
                    )

                    // Climate button (context-sensitive)
                    WatchVehicleButton(
                        currentAction: isClimateRunning ? stopClimateAction : startClimateAction,
                        allActions: [startClimateAction, stopClimateAction],
                        menuLabel: "Climate Actions",
                        vehicle: vehicle,
                    )

                    // Charge button (only for plugged-in electric vehicles)
                    if isPluggedIn {
                        WatchVehicleButton(
                            currentAction: isCharging ? stopChargeAction : startChargeAction,
                            allActions: [startChargeAction, stopChargeAction],
                            menuLabel: "Charge Actions",
                            vehicle: vehicle,
                        )
                    }
                }
            }
            .padding()
        }
        .onAppear {
            // Auto-refresh if data is older than 5 minutes
            if let lastUpdated = currentVehicle.lastUpdated,
               lastUpdated < Date().addingTimeInterval(-300) {
                Task {
                    await refreshStatus()
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            WatchVehicleSettingsView(vehicle: currentVehicle)
        }
        //        .navigationTitle(vehicle.displayName)
    }

    private func formatUpdateTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        if calendar.isDateInToday(date) {
            return "Today at \(timeFormatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday at \(timeFormatter.string(from: date))"
        } else {
            let dayFormatter = DateFormatter()
            dayFormatter.dateStyle = .medium
            dayFormatter.timeStyle = .short
            return dayFormatter.string(from: date)
        }
    }

    @MainActor
    private func refreshStatus() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        // First, force SwiftData to refetch data by accessing model properties
        // This ensures we get the latest data including background colors from CloudKit sync
        print("🔄 [WatchVehicle] Force refreshing SwiftData for all vehicles")
        for vehicle in allVehicles {
            _ = vehicle.watchBackgroundColorName
            _ = vehicle.watchBackgroundGradient
        }

        do {
            guard let account = currentVehicle.account else {
                throw HyundaiKiaAPIError(message: "Account not found for vehicle")
            }

            let status = try await account.fetchVehicleStatus(for: currentVehicle, modelContext: modelContext)
            currentVehicle.updateStatus(with: status)
            lastRefreshDate = Date()

        } catch {
            print("❌ [WatchVehicle] Failed to refresh status: \(error)")
        }
    }

    private func performLockAction(shouldLock: Bool, statusUpdater: @escaping @Sendable (String) -> Void) async throws {
        guard let account = currentVehicle.account else {
            throw HyundaiKiaAPIError(message: "Account not found for vehicle")
        }

        if shouldLock {
            try await account.lockVehicle(currentVehicle, modelContext: modelContext)
        } else {
            try await account.unlockVehicle(currentVehicle, modelContext: modelContext)
        }

        let targetLockStatus: VehicleStatus.LockStatus = shouldLock ? .locked : .unlocked
        try await currentVehicle.waitForStatusChange(
            modelContext: modelContext,
            condition: { status in
                status.lockStatus == targetLockStatus
            },
            statusMessageUpdater: statusUpdater,
        )
    }

    private func performClimateAction(shouldStart: Bool, statusUpdater: @escaping @Sendable (String) -> Void) async throws {
        guard let account = currentVehicle.account else {
            throw HyundaiKiaAPIError(message: "Account not found for vehicle")
        }

        if shouldStart {
            try await account.startClimate(currentVehicle, modelContext: modelContext)
        } else {
            try await account.stopClimate(currentVehicle, modelContext: modelContext)
        }

        try await currentVehicle.waitForStatusChange(
            modelContext: modelContext,
            condition: { status in
                status.climateStatus.airControlOn == shouldStart
            },
            statusMessageUpdater: statusUpdater,
        )
    }

    private func performChargeAction(shouldStart: Bool, statusUpdater: @escaping @Sendable (String) -> Void) async throws {
        guard let account = currentVehicle.account else {
            throw HyundaiKiaAPIError(message: "Account not found for vehicle")
        }

        if shouldStart {
            try await account.startCharge(currentVehicle, modelContext: modelContext)
        } else {
            try await account.stopCharge(currentVehicle, modelContext: modelContext)
        }

        try await currentVehicle.waitForStatusChange(
            modelContext: modelContext,
            condition: { status in
                status.evStatus?.charging == shouldStart
            },
            statusMessageUpdater: statusUpdater,
        )
    }
}

// Watch-specific vehicle button component using VehicleAction architecture
struct WatchVehicleButton: View {
    let currentAction: MainVehicleAction
    let allActions: [MainVehicleAction]
    let menuLabel: String
    let vehicle: BBVehicle

    @State private var inProgressAction: MainVehicleAction?
    @State private var currentTask: Task<Void, Never>?
    @State private var showingMenu = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if inProgressAction != nil {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: currentAction.icon)
                        .spin(currentAction.shouldRotate)
                        .pulse(currentAction.shouldPulse)
                        .foregroundColor(currentAction.color)
                }
            }
            .frame(width: 24, height: 24)

            Text(inProgressAction?.inProgressLabel ?? currentAction.label)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            if inProgressAction != nil {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 24, height: 24)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .glassEffect()
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    if inProgressAction == nil {
                        performPrimaryAction()
                    } else {
                        currentTask?.cancel()
                        Task {
                            await vehicle.clearPendingStatusWaiters()
                        }
                        inProgressAction = nil
                    }
                },
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.7)
                .onEnded { _ in
                    showingMenu = true
                },
        )
        .confirmationDialog(menuLabel, isPresented: $showingMenu, titleVisibility: .visible) {
            ForEach(Array(allActions.enumerated()), id: \.offset) { _, action in
                Button(action.label) {
                    performAction(action)
                }
            }
        }
    }

    private func performPrimaryAction() {
        performAction(currentAction)
    }

    private func performAction(_ action: MainVehicleAction) {
        currentTask = Task {
            await MainActor.run {
                inProgressAction = action
            }

            do {
                try await action.action { _ in }
                await MainActor.run {
                    inProgressAction = nil
                }
            } catch {
                print("❌ [WatchVehicleButton] Action failed: \(error)")
                await MainActor.run {
                    inProgressAction = nil
                }
            }
        }
    }
}

#Preview {
    let schema = Schema([
        BBAccount.self,
        BBVehicle.self,
        BBHTTPLog.self,
        ClimatePreset.self
    ])
    let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [modelConfiguration])

    let sampleVehicle = BBVehicle(from: Vehicle(
        vin: "test",
        regId: "test",
        model: "Ioniq 5",
        accountId: UUID(),
        isElectric: true,
        generation: 3,
        odometer: Distance(length: 25000, units: .miles),
        vehicleKey: nil,
    ), backgroundColorName: "lightBlue")

    WatchVehicleView(vehicle: sampleVehicle)
        .modelContainer(container)
}
