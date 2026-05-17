//
//  LiveActivityManager.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 12/13/25.
//

#if canImport(ActivityKit)
import ActivityKit
#endif
import BetterBlueKit
import Foundation
import OSLog
import SwiftData
import UIKit
import WidgetKit

#if DEBUG
private let liveActivityBackendURL = "https://phgu023o97.execute-api.us-east-1.amazonaws.com/dev"
#else
private let liveActivityBackendURL = "https://6rx06wxs8f.execute-api.us-east-1.amazonaws.com/prod"
#endif

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var deviceToken: String?
    private var isRegisteredWithBackend = false

    private init() {}

    func setDeviceToken(_ token: String) {
        deviceToken = token
        AppLogger.liveActivity.info("Device token set: \(token.prefix(20), privacy: .public)...")

        // If we have active Live Activities, register with backend now
        #if canImport(ActivityKit)
        if let activity = Activity<VehicleActivityAttributes>.activities.first, !isRegisteredWithBackend {
            let activityType = activity.content.state.activityType
            Task {
                await registerWithBackend(activityType: activityType)
            }
        }
        #endif
    }

    /// Handle a wakeup push from the backend - fetch fresh data and update all Live Activities
    ///
    /// Restructured to minimise SwiftData lock hold time during the
    /// background wakeup window. The old shape held the container's
    /// `mainContext` for the entire loop body, which kept a SQLite
    /// connection live across multiple seconds of HTTP — exactly the
    /// pattern that trips RunningBoard's 0xdead10cc kill if iOS
    /// suspends us mid-request. The new shape:
    ///
    ///   1. Snapshots only the active live-activity VINs (Sendable
    ///      strings) so we don't iterate `Activity.activities` from
    ///      inside a SwiftData scope.
    ///   2. For each VIN, opens a *fresh* `ModelContext` in a tight
    ///      `do { … }` block. Fetch → HTTP → save → drop. SwiftData
    ///      releases that context's tracking state at scope exit;
    ///      saves complete promptly because change sets are small.
    ///   3. Saves explicitly with `try context.save()` so writes flush
    ///      before the context drops (the default fresh context does
    ///      not autosave the way `mainContext` does).
    ///   4. Defers the `refreshActivity(…)` ActivityKit update until
    ///      *after* the SwiftData scope, so there's no chance of the
    ///      live-activity push holding open the SQLite connection.
    func handleWakeupPush() async {
        AppLogger.liveActivity.info("Handling wakeup push...")

        #if canImport(ActivityKit)
        // Snapshot just the VINs — Sendable strings — so iteration
        // happens outside any SwiftData scope.
        let activityVINs = Activity<VehicleActivityAttributes>.activities.map { $0.attributes.vin }
        guard !activityVINs.isEmpty else {
            AppLogger.liveActivity.info("No active Live Activities to update")
            return
        }

        // Open one container for the whole call (creating one per
        // iteration is wasteful — it'd reinit the SQLite connection
        // pool each time). Per-iteration `ModelContext` instances
        // share this container but scope their own change tracking.
        guard let container = try? createSharedModelContainer() else {
            AppLogger.liveActivity.error("Failed to create model container")
            return
        }

        for vin in activityVINs {
            AppLogger.liveActivity.info("Updating Live Activity for VIN: \(vin.prefix(8), privacy: .public)...")

            // Per-iteration scope: fresh context, save, drop at end.
            // Holding the context across the HTTP boundary is
            // unavoidable for now (BBAccount.fetchVehicleStatus takes
            // a ModelContext for HTTP logging + token persistence),
            // but limiting the change-tracking window to one activity
            // at a time keeps each save fast and short.
            let status: VehicleStatus?
            do {
                status = try await updateVehicleStatus(vin: vin, container: container)
            } catch {
                AppLogger.liveActivity.error("Error updating Live Activity for \(vin.prefix(8), privacy: .public): \(error)")
                status = nil
            }

            // ActivityKit refresh is independent of SwiftData — do it
            // outside the per-iteration context scope so the push
            // doesn't extend the lock-hold window.
            if let status {
                await refreshActivity(for: vin, status: status, incrementWakeup: true)
                AppLogger.liveActivity.info("Updated Live Activity for \(vin.prefix(8), privacy: .public)")
            }
        }
        #endif
    }

    /// Per-activity SwiftData scope. Opens a fresh `ModelContext`,
    /// fetches the vehicle, fires the HTTP refresh, persists, and
    /// returns the new status to the caller. The context drops when
    /// this function returns, so SwiftData releases its change-
    /// tracking state immediately rather than carrying it across
    /// every other activity in the same push batch.
    private func updateVehicleStatus(
        vin: String,
        container: ModelContainer
    ) async throws -> VehicleStatus? {
        let context = ModelContext(container)

        let predicate = #Predicate<BBVehicle> { $0.vin == vin }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let vehicle = try context.fetch(descriptor).first,
              let account = vehicle.account else {
            AppLogger.liveActivity.error("Vehicle or account not found for VIN: \(vin.prefix(8), privacy: .public)")
            return nil
        }

        try await account.initialize(modelContext: context, deviceType: .liveActivity)
        let status = try await account.fetchVehicleStatus(for: vehicle, modelContext: context)

        vehicle.updateStatus(with: status)
        try context.save()
        return status
    }

    func updateActivity(for vehicle: BBVehicle, status: VehicleStatus, modelContext: ModelContext) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var type: LiveActivityType = .none

        if vehicle.debugLiveActivity {
            type = .debug
        } else if status.evStatus?.charging == true {
            type = .charging
        }
        // Note: Climate live activity removed due to infrequent updates making it a poor UX

        if type != .none {
            startOrUpdateActivity(for: vehicle, status: status, type: type)
        } else {
            endActivity(for: vehicle)
        }
        #endif
    }

    nonisolated func refreshActivity(for vin: String, status: VehicleStatus, incrementWakeup: Bool = false) async {
        #if canImport(ActivityKit)
        guard let existingActivity = Activity<VehicleActivityAttributes>.activities.first(where: { $0.attributes.vin == vin }) else {
            return
        }

        let currentState = existingActivity.content.state
        let updatedState = VehicleActivityAttributes.ContentState(
            status: status,
            activityType: currentState.activityType,
            activityState: currentState.activityState,
            isRefreshing: false,
            climatePresetName: currentState.climatePresetName,
            climatePresetIcon: currentState.climatePresetIcon,
            wakeupCount: incrementWakeup ? currentState.wakeupCount + 1 : currentState.wakeupCount,
            lastWakeupTime: incrementWakeup ? Date() : currentState.lastWakeupTime
        )

        await existingActivity.update(ActivityContent(state: updatedState, staleDate: nil))

        // Refresh widgets to stay in sync with live activity
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    nonisolated func setRefreshing(for vin: String, isRefreshing: Bool) async {
        #if canImport(ActivityKit)
        guard let existingActivity = Activity<VehicleActivityAttributes>.activities.first(where: { $0.attributes.vin == vin }) else {
            return
        }

        let currentState = existingActivity.content.state
        let updatedState = VehicleActivityAttributes.ContentState(
            status: currentState.status,
            activityType: currentState.activityType,
            activityState: currentState.activityState,
            isRefreshing: isRefreshing,
            climatePresetName: currentState.climatePresetName,
            climatePresetIcon: currentState.climatePresetIcon,
            wakeupCount: currentState.wakeupCount,
            lastWakeupTime: currentState.lastWakeupTime
        )

        await existingActivity.update(ActivityContent(state: updatedState, staleDate: nil))
        #endif
    }

    /// Start or stop the debug Live Activity based on the vehicle's debugLiveActivity flag
    func updateDebugActivity(for vehicle: BBVehicle) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if vehicle.debugLiveActivity {
            // Start the debug Live Activity
            guard let status = createStatusFromVehicle(vehicle) else {
                AppLogger.liveActivity.error("Cannot start debug activity: missing vehicle status")
                return
            }
            startOrUpdateActivity(for: vehicle, status: status, type: .debug)
        } else {
            // End the debug Live Activity
            endActivity(for: vehicle)
        }
        #endif
    }

    func startCommandActivity(
        for vehicle: BBVehicle,
        type: LiveActivityType,
        modelContext: ModelContext,
        climatePresetName: String? = nil,
        climatePresetIcon: String? = nil
    ) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let status = createStatusFromVehicle(vehicle) else { return }

        startOrUpdateActivity(
            for: vehicle,
            status: status,
            type: type,
            climatePresetName: climatePresetName,
            climatePresetIcon: climatePresetIcon
        )

        // Poll for state change in background
        Task {
            var taskId = UIBackgroundTaskIdentifier.invalid
            if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication {
                taskId = app.beginBackgroundTask { }
            }

            defer {
                if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication, taskId != .invalid {
                    app.endBackgroundTask(taskId)
                }
            }

            for _ in 1...3 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let account = vehicle.account else { break }
                try? await account.fetchAndUpdateVehicleStatus(for: vehicle, modelContext: modelContext)

                if (type == .climate && vehicle.climateStatus?.airControlOn == true) ||
                    (type == .charging && vehicle.evStatus?.charging == true) {
                    break
                }
            }

            // If state didn't change, end the activity after a delay
            if (type == .climate && vehicle.climateStatus?.airControlOn != true) ||
                (type == .charging && vehicle.evStatus?.charging != true) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                endActivity(for: vehicle)
            }
        }
        #endif
    }

    private func createStatusFromVehicle(_ vehicle: BBVehicle) -> VehicleStatus? {
        guard let location = vehicle.location,
              let lock = vehicle.lockStatus,
              let climate = vehicle.climateStatus else { return nil }

        return VehicleStatus(
            vin: vehicle.vin,
            gasRange: vehicle.gasRange,
            evStatus: vehicle.evStatus,
            location: location,
            lockStatus: lock,
            climateStatus: climate,
            odometer: vehicle.odometer,
            syncDate: vehicle.syncDate
        )
    }

    private func startOrUpdateActivity(
        for vehicle: BBVehicle,
        status: VehicleStatus,
        type: LiveActivityType,
        climatePresetName: String? = nil,
        climatePresetIcon: String? = nil
    ) {
        #if canImport(ActivityKit)
        let existingActivity = Activity<VehicleActivityAttributes>.activities.first { $0.attributes.vin == vehicle.vin }

        let contentState: VehicleActivityAttributes.ContentState
        if let activity = existingActivity {
            let currentState = activity.content.state
            contentState = VehicleActivityAttributes.ContentState(
                status: status,
                activityType: type,
                activityState: currentState.activityState,
                climatePresetName: climatePresetName ?? currentState.climatePresetName,
                climatePresetIcon: climatePresetIcon ?? currentState.climatePresetIcon,
                wakeupCount: currentState.wakeupCount,
                lastWakeupTime: currentState.lastWakeupTime
            )
        } else {
            contentState = VehicleActivityAttributes.ContentState(
                status: status,
                activityType: type,
                climatePresetName: climatePresetName,
                climatePresetIcon: climatePresetIcon
            )
        }

        if let activity = existingActivity {
            nonisolated(unsafe) let activity = activity
            Task { @MainActor in
                await activity.update(ActivityContent(state: contentState, staleDate: nil))
            }
        } else {
            let attributes = VehicleActivityAttributes(
                vehicleName: vehicle.displayName,
                vin: vehicle.vin,
                vehicleId: vehicle.id,
                startClimateColorName: vehicle.startClimateColorName,
                chargingColorName: vehicle.chargingColorName
            )
            do {
                _ = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: nil),
                    pushType: nil // We don't use Live Activity push tokens anymore
                )
                // Register with backend for wakeup pushes with the activity type
                Task {
                    await registerWithBackend(activityType: type)
                }
            } catch {
                AppLogger.liveActivity.error("Error requesting activity: \(error)")
            }
        }
        #endif
    }

    private func registerWithBackend(activityType: LiveActivityType = .charging) async {
        guard let deviceToken = deviceToken else {
            AppLogger.liveActivity.warning("No device token available for backend registration")
            return
        }

        // Only charging and debug get backend wakeup pushes. Climate
        // activities are short-lived and driven by the foregrounded
        // app's polling — registering them just stuffs the wakeup
        // table with rows that don't need long-term refresh. The
        // backend now rejects them with 400 too.
        guard activityType == .charging || activityType == .debug else {
            AppLogger.liveActivity.info(
                "Skipping backend registration for short-lived activity type: \(activityType.rawValue, privacy: .public)"
            )
            return
        }

        guard let url = URL(string: "\(liveActivityBackendURL)/wakeup") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "pushToken": deviceToken,
            "activityType": activityType.rawValue  // "charging" or "debug"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    isRegisteredWithBackend = true
                    AppLogger.liveActivity.info("Registered with backend for wakeup pushes (type: \(activityType.rawValue, privacy: .public))")
                } else {
                    AppLogger.liveActivity.error("Backend registration failed: \(httpResponse.statusCode)")
                }
            }
        } catch {
            AppLogger.liveActivity.error("Backend registration error: \(error)")
        }
    }

    private func unregisterFromBackend() async {
        guard let deviceToken = deviceToken else { return }
        guard let url = URL(string: "\(liveActivityBackendURL)/wakeup/unregister") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["pushToken": deviceToken]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            _ = try await URLSession.shared.data(for: request)
            isRegisteredWithBackend = false
            AppLogger.liveActivity.info("Unregistered from backend")
        } catch {
            AppLogger.liveActivity.error("Backend unregistration error: \(error)")
        }
    }

    private func endActivity(for vehicle: BBVehicle) {
        #if canImport(ActivityKit)
        guard let existingActivity = Activity<VehicleActivityAttributes>.activities.first(where: { $0.attributes.vin == vehicle.vin }) else {
            return
        }

        nonisolated(unsafe) let activity = existingActivity
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)

            // If no more active Live Activities, unregister from backend
            if Activity<VehicleActivityAttributes>.activities.count <= 1 {
                await unregisterFromBackend()
            }
        }
        #endif
    }
}

// MARK: - Types

public enum LiveActivityState: String, Codable, Hashable, Sendable {
    case starting, running, failed
}

public enum LiveActivityType: String, Codable, Hashable, Sendable {
    case climate, charging, debug, none

    public func message(for state: LiveActivityState) -> String {
        switch (self, state) {
        case (.climate, .starting): return "Starting Climate..."
        case (.climate, .running): return "Climate Active"
        case (.climate, .failed): return "Climate Failed"
        case (.charging, .starting): return "Starting Charge..."
        case (.charging, .running): return "Charging"
        case (.charging, .failed): return "Charge Failed"
        case (.debug, .starting): return "Debug Starting..."
        case (.debug, .running): return "Debug Active"
        case (.debug, .failed): return "Debug Failed"
        case (.none, .starting): return "Updating..."
        case (.none, .running): return "Updated"
        case (.none, .failed): return "Update Failed"
        }
    }

    public var refreshIntervalMinutes: Int {
        return 1
    }
}

// MARK: - Activity Attributes

#if canImport(ActivityKit)
public struct VehicleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: VehicleStatus
        public var activityType: LiveActivityType
        public var activityState: LiveActivityState
        public var isRefreshing: Bool
        public var climatePresetName: String?
        public var climatePresetIcon: String?
        // Debug fields
        public var wakeupCount: Int
        public var lastWakeupTime: Date?

        public init(
            status: VehicleStatus,
            activityType: LiveActivityType = .none,
            activityState: LiveActivityState = .running,
            isRefreshing: Bool = false,
            climatePresetName: String? = nil,
            climatePresetIcon: String? = nil,
            wakeupCount: Int = 0,
            lastWakeupTime: Date? = nil
        ) {
            self.status = status
            self.activityType = activityType
            self.activityState = activityState
            self.isRefreshing = isRefreshing
            self.climatePresetName = climatePresetName
            self.climatePresetIcon = climatePresetIcon
            self.wakeupCount = wakeupCount
            self.lastWakeupTime = lastWakeupTime
        }
    }

    public var vehicleName: String
    public var vin: String
    public var vehicleId: UUID
    /// Per-vehicle accent colors. Captured at activity-start time so the
    /// Live Activity can render in the user's chosen palette without doing
    /// SwiftData lookups in the widget process. Already-running activities
    /// won't reflect changes until the activity is restarted.
    public var startClimateColorName: String?
    public var chargingColorName: String?

    public init(
        vehicleName: String,
        vin: String,
        vehicleId: UUID,
        startClimateColorName: String? = nil,
        chargingColorName: String? = nil
    ) {
        self.vehicleName = vehicleName
        self.vin = vin
        self.vehicleId = vehicleId
        self.startClimateColorName = startClimateColorName
        self.chargingColorName = chargingColorName
    }
}
#endif
