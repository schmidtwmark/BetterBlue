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
    func handleWakeupPush() async {
        AppLogger.liveActivity.info("Handling wakeup push...")

        #if canImport(ActivityKit)
        let activities = Activity<VehicleActivityAttributes>.activities
        guard !activities.isEmpty else {
            AppLogger.liveActivity.info("No active Live Activities to update")
            return
        }

        // Get the model container to fetch vehicle data
        guard let container = try? createSharedModelContainer() else {
            AppLogger.liveActivity.error("Failed to create model container")
            return
        }

        let context = container.mainContext

        for activity in activities {
            let vin = activity.attributes.vin
            AppLogger.liveActivity.info("Updating Live Activity for VIN: \(vin.prefix(8), privacy: .public)...")

            do {
                // Fetch the vehicle
                let predicate = #Predicate<BBVehicle> { $0.vin == vin }
                var descriptor = FetchDescriptor(predicate: predicate)
                descriptor.fetchLimit = 1

                guard let vehicle = try context.fetch(descriptor).first,
                      let account = vehicle.account else {
                    AppLogger.liveActivity.error("Vehicle or account not found for VIN: \(vin.prefix(8), privacy: .public)")
                    continue
                }

                // Initialize account with Live Activity device type for HTTP logging
                try await account.initialize(modelContext: context, deviceType: .liveActivity)

                // Fetch fresh status (async call)
                let status = try await account.fetchVehicleStatus(for: vehicle, modelContext: context)

                // Update vehicle with new status
                vehicle.updateStatus(with: status)

                // Update the Live Activity with increment wakeup count
                await refreshActivity(for: vin, status: status, incrementWakeup: true)

                AppLogger.liveActivity.info("Updated Live Activity for \(vin.prefix(8), privacy: .public)")
            } catch {
                AppLogger.liveActivity.error("Error updating Live Activity for \(vin.prefix(8), privacy: .public): \(error)")
            }
        }
        #endif
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
            Task {
                await activity.update(ActivityContent(state: contentState, staleDate: nil))
            }
        } else {
            let attributes = VehicleActivityAttributes(
                vehicleName: vehicle.displayName,
                vin: vehicle.vin,
                vehicleId: vehicle.id
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
        guard let activity = Activity<VehicleActivityAttributes>.activities.first(where: { $0.attributes.vin == vehicle.vin }) else {
            return
        }

        Task {
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

    public init(vehicleName: String, vin: String, vehicleId: UUID) {
        self.vehicleName = vehicleName
        self.vin = vin
        self.vehicleId = vehicleId
    }
}
#endif
