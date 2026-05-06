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
    /// Single error-sheet anchor for the whole vehicle page. Both
    /// refresh failures (here) and action failures (forwarded from
    /// child WatchVehicleButtons) write here, but only when it's
    /// currently nil — so a new failure can never replace a sheet that
    /// is already presenting.
    @State private var lastError: WatchActionError?
    @Query private var allVehicles: [BBVehicle]
    @Environment(\.modelContext) private var modelContext

    // Get the latest background info for this vehicle from the query
    private var currentVehicle: BBVehicle {
        allVehicles.first(where: { $0.vin == vehicle.vin }) ?? vehicle
    }

    private var batteryPercentage: Int? {
        guard currentVehicle.fuelType.hasElectricCapability, let evStatus = currentVehicle.evStatus else { return nil }
        return Int(evStatus.evRange.percentage)
    }

    private var fuelPercentage: Int? {
        guard !currentVehicle.fuelType.hasElectricCapability, let gasRange = currentVehicle.gasRange else { return nil }
        return Int(gasRange.percentage)
    }

    private var rangeText: String {
        if currentVehicle.fuelType.hasElectricCapability, let evStatus = currentVehicle.evStatus {
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
        guard currentVehicle.fuelType.hasElectricCapability, let evStatus = currentVehicle.evStatus else { return false }
        return evStatus.pluggedIn
    }

    private var isCharging: Bool {
        guard currentVehicle.fuelType.hasElectricCapability, let evStatus = currentVehicle.evStatus else { return false }
        return evStatus.charging
    }

    // VehicleAction instances
    //
    // The status icon is anchored to the *current* vehicle state (not the
    // action's destination), so the colors here pair with the action's
    // `stateLabel` to match the iOS LockButton convention:
    //   • lockAction is shown when the car is currently UNLOCKED → use unlockColor
    //   • unlockAction is shown when the car is currently LOCKED → use lockColor
    private var lockAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performLockAction(shouldLock: true, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "lock.open.fill"),
            label: "Lock",
            inProgressLabel: "Locking",
            completedText: "Locked",
            color: currentVehicle.unlockColor,
            stateLabel: "Unlocked"
        )
    }

    private var unlockAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performLockAction(shouldLock: false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "lock.fill"),
            label: "Unlock",
            inProgressLabel: "Unlocking",
            completedText: "Unlocked",
            color: currentVehicle.lockColor,
            stateLabel: "Locked"
        )
    }

    private var startClimateAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performClimateAction(shouldStart: true, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "fan.slash"),
            label: "Start Climate",
            inProgressLabel: "Starting",
            completedText: "Started",
            color: .secondary,
            stateLabel: "Climate Off"
        )
    }

    private var stopClimateAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performClimateAction(shouldStart: false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "fan"),
            label: "Stop Climate",
            inProgressLabel: "Stopping",
            completedText: "Stopped",
            color: currentVehicle.startClimateColor,
            stateLabel: "Climate Running",
            shouldRotate: true
        )
    }

    private var startChargeAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performChargeAction(shouldStart: true, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "bolt.slash"),
            label: "Start Charge",
            inProgressLabel: "Starting",
            completedText: "Charging",
            color: .secondary,
            stateLabel: "Not Charging"
        )
    }

    private var stopChargeAction: MainVehicleAction {
        MainVehicleAction(
            action: { statusUpdater in
                try await performChargeAction(shouldStart: false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "bolt.fill"),
            label: "Stop Charge",
            inProgressLabel: "Stopping",
            completedText: "Stopped",
            color: currentVehicle.chargingColor,
            stateLabel: "Charging",
            shouldPulse: true
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Header doubles as the refresh affordance: a tap on the
                // title triggers a status refresh. While the refresh is
                // in-flight the "last updated" line swaps for an inline
                // ProgressView so the user sees something is happening
                // without having to look elsewhere on the screen.
                Button {
                    Task { await refreshStatus() }
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
                            Image(systemName: currentVehicle.fuelType.hasElectricCapability ? "bolt.fill" : "fuelpump.fill")
                                .foregroundColor(currentVehicle.fuelType.hasElectricCapability ? currentVehicle.chargingColor : .orange)
                                .font(.caption)

                            Text(rangeText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        HStack {
                            if isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Refreshing…")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            } else if let lastUpdated = currentVehicle.lastUpdated {
                                Text(formatUpdateTime(lastUpdated))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)

                // Context-sensitive action buttons
                VStack(spacing: 8) {
                    // Lock/Unlock button (context-sensitive)
                    WatchVehicleButton(
                        currentAction: isLocked ? unlockAction : lockAction,
                        allActions: [lockAction, unlockAction],
                        menuLabel: "Door Actions",
                        vehicle: vehicle,
                        sharedError: $lastError,
                    )

                    // Climate button (context-sensitive)
                    WatchVehicleButton(
                        currentAction: isClimateRunning ? stopClimateAction : startClimateAction,
                        allActions: [startClimateAction, stopClimateAction],
                        menuLabel: "Climate Actions",
                        vehicle: vehicle,
                        sharedError: $lastError,
                    )

                    // Charge button (only for plugged-in electric vehicles)
                    if isPluggedIn {
                        WatchVehicleButton(
                            currentAction: isCharging ? stopChargeAction : startChargeAction,
                            allActions: [startChargeAction, stopChargeAction],
                            menuLabel: "Charge Actions",
                            vehicle: vehicle,
                            sharedError: $lastError,
                        )
                    }
                }

                // Settings button at the very bottom of the scroll view —
                // the title tap is the refresh affordance, so settings
                // gets its own row that the user scrolls down to reach.
                Button {
                    showingSettings = true
                } label: {
                    // Matches WatchVehicleButton's spacing/sizing so the
                    // gear lines up with the action-button icons above.
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .frame(width: 24, height: 24)
                        Text("Settings")
                            .fontWeight(.medium)
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
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
        // One shared error sheet for refresh + every action button on
        // this page. `item:` form means the sheet only mounts when an
        // error exists; dismissing nils it out, freeing the slot for
        // the next failure.
        .sheet(item: $lastError) { actionError in
            WatchErrorSheet(error: actionError) {
                lastError = nil
            }
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
                throw APIError(message: "Account not found for vehicle")
            }

            // Watch refresh is always user-initiated (tap or view appear);
            // force a real-time poll so it matches the MyHyundai/Kia Connect
            // behaviour users expect.
            let status = try await account.fetchVehicleStatus(
                for: currentVehicle,
                modelContext: modelContext,
                cached: false
            )
            currentVehicle.updateStatus(with: status)
            lastRefreshDate = Date()

        } catch {
            BBLogger.warning(.app, "WatchVehicle: failed to refresh status: \(error)")
            // Don't stomp on an already-visible error sheet — the user
            // is still reading the previous failure.
            if lastError == nil {
                lastError = WatchActionError(action: "Refresh", error: error)
            }
        }
    }

    private func performLockAction(shouldLock: Bool, statusUpdater: @escaping @Sendable (String) -> Void) async throws {
        guard let account = currentVehicle.account else {
            throw APIError(message: "Account not found for vehicle")
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
            throw APIError(message: "Account not found for vehicle")
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
            throw APIError(message: "Account not found for vehicle")
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
    /// Page-level error slot owned by `WatchVehicleView`. We only ever
    /// write to it when it's currently nil, so an existing sheet never
    /// gets blown away by a new failure.
    @Binding var sharedError: WatchActionError?

    @State private var inProgressAction: MainVehicleAction?
    @State private var currentTask: Task<Void, Never>?
    @State private var showingMenu = false

    var body: some View {
        HStack(spacing: 8) {
            // Anchor the icon's layout box with a fixed-size Color.clear
            // and render the (possibly animating) icon as an overlay.
            // - Explicit `.font(.body)` keeps the symbol's intrinsic
            //   size stable so spin/pulse can't grow it past the box.
            // - `.geometryGroup()` (watchOS 10+) isolates this subtree's
            //   layout from parent transaction propagation, which is
            //   what was making the entire row bob with the animation.
            Color.clear
                .frame(width: 24, height: 24)
                .overlay {
                    if inProgressAction != nil {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        currentAction.icon
                            .font(.body)
                            .foregroundColor(currentAction.color)
                            .spin(currentAction.shouldRotate)
                            .pulse(currentAction.shouldPulse)
                    }
                }
                .geometryGroup()

            Text(inProgressAction?.inProgressLabel ?? currentAction.stateLabel)
                .fontWeight(.medium)
                .lineLimit(1)
                // Watch screens are narrow; let labels like "Climate
                // Running" or "Unlocking" shrink instead of truncating.
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
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
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
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
                BBLogger.warning(.app, "WatchVehicleButton: action failed: \(error)")
                await MainActor.run {
                    inProgressAction = nil
                    // Match the iOS catch site: prefer the action's
                    // completedText (verb-noun like "Lock vehicle"),
                    // fall back to the menu label. Only set if the
                    // page-level slot is currently empty so we don't
                    // displace an already-visible error sheet.
                    if sharedError == nil {
                        // Imperative `label` ("Lock", "Start Climate")
                        // reads grammatically after "Failed to …" in
                        // the sheet headline; `completedText` would
                        // give "Failed to locked." which is wrong.
                        sharedError = WatchActionError(action: action.label, error: error)
                    }
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
        fuelType: .electric,
        generation: 3,
        odometer: Distance(length: 25000, units: .miles),
        vehicleKey: nil,
    ), backgroundColorName: "lightBlue")

    WatchVehicleView(vehicle: sampleVehicle)
        .modelContainer(container)
}
