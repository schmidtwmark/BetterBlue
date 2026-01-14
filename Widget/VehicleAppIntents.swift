//
//  VehicleAppIntents.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

#if canImport(ActivityKit)
import ActivityKit
#endif
import AppIntents
import BetterBlueKit
import SwiftData
import UserNotifications
import WidgetKit

// MARK: - AppEnum Conformance for LiveActivityType

extension LiveActivityType: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Activity Type")
    }

    public static var caseDisplayRepresentations: [LiveActivityType: DisplayRepresentation] {
        [
            .climate: DisplayRepresentation(title: "Climate"),
            .charging: DisplayRepresentation(title: "Charging"),
            .none: DisplayRepresentation(title: "None"),
        ]
    }

    public static var allCases: [LiveActivityType] {
        [.climate, .charging, .none]
    }
}

// MARK: - Live Activity Intents

struct StopLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Live Activity"
    static var description = IntentDescription("Stop the current activity (climate or charging)")

    @Parameter(title: "VIN")
    var vin: String

    @Parameter(title: "Activity Type")
    var activityType: LiveActivityType

    init() {
        vin = ""
        activityType = .none
    }

    init(vin: String, activityType: LiveActivityType) {
        self.vin = vin
        self.activityType = activityType
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if canImport(ActivityKit)
        print("🛑 [StopLiveActivityIntent] Starting for VIN: \(vin), type: \(activityType)")

        // Find the existing activity
        let activities = Activity<VehicleActivityAttributes>.activities
        guard let existingActivity = activities.first(where: { $0.attributes.vin == vin }) else {
            print("❌ [StopLiveActivityIntent] No activity found for VIN: \(vin)")
            return .result()
        }

        // Fetch the vehicle and account
        let modelContainer = try createSharedModelContainer()
        let context = ModelContext(modelContainer)
        let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        guard let bbVehicle = vehicles.first(where: { $0.vin == vin }),
              let account = bbVehicle.account
        else {
            print("❌ [StopLiveActivityIntent] Vehicle or account not found for VIN: \(vin)")
            return .result()
        }

        // Send the appropriate stop command
        do {
            switch activityType {
            case .climate:
                print("🛑 [StopLiveActivityIntent] Stopping climate...")
                try await account.stopClimate(bbVehicle, modelContext: context)
            case .charging:
                print("🛑 [StopLiveActivityIntent] Stopping charge...")
                try await account.stopCharge(bbVehicle, modelContext: context)
            case .debug:
                print("🛑 [StopLiveActivityIntent] Stopping debug activity...")
                bbVehicle.debugLiveActivity = false
                try context.save()
            case .none:
                print("⚠️ [StopLiveActivityIntent] Activity type is .none, nothing to stop")
            }

            // End the Live Activity
            await existingActivity.end(nil, dismissalPolicy: .immediate)
            print("✅ [StopLiveActivityIntent] Activity ended successfully")

            // Send notification
            let actionName: String
            switch activityType {
            case .climate: actionName = "Climate"
            case .charging: actionName = "Charging"
            case .debug: actionName = "Debug"
            case .none: actionName = "Activity"
            }
            await sendNotification(title: "\(actionName) Stop Sent", body: "Command sent to \(bbVehicle.displayName)")

        } catch {
            print("❌ [StopLiveActivityIntent] Error: \(error)")
        }

        return .result()
        #else
        return .result()
        #endif
    }
}

struct RefreshVehicleStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Vehicle Status"
    static var description = IntentDescription("Refresh the status of your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to refresh")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let modelContainer = try createSharedModelContainer()
        let context = ModelContext(modelContainer)

        let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        guard let bbVehicle = vehicles.first(where: { $0.vin == vehicle.vin }),
              let account = bbVehicle.account
        else {
            throw IntentError.vehicleNotFound
        }

        try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)

        let unit = AppSettings.shared.preferredDistanceUnit
        let allPresets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        let updatedVehicle = VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)

        WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")

        return .result(dialog: "\(updatedVehicle.displayName) status updated. \(updatedVehicle.rangeText)")
    }
}

struct GetVehicleStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Vehicle Status"
    static var description = IntentDescription("Get the current status of your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to check")
    var vehicle: VehicleEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let modelContainer = try createSharedModelContainer()
        let context = ModelContext(modelContainer)

        let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        guard let bbVehicle = vehicles.first(where: { $0.vin == vehicle.vin }) else {
            throw IntentError.vehicleNotFound
        }

        var statusComponents: [String] = []

        // Lock status
        if let lockStatus = bbVehicle.lockStatus {
            let lockText = lockStatus == .locked ? "locked" : "unlocked"
            statusComponents.append("Vehicle is \(lockText)")
        }

        // Range and battery/fuel information
        statusComponents.append("Range: \(vehicle.rangeText)")

        // EV specific status
        if bbVehicle.isElectric, let evStatus = bbVehicle.evStatus {
            statusComponents.append("Battery: \(Int(evStatus.evRange.percentage))%")

            if evStatus.pluggedIn {
                if evStatus.charging {
                    if evStatus.chargeSpeed > 0 {
                        statusComponents.append("Charging at \(evStatus.chargeSpeed) kW")
                    } else {
                        statusComponents.append("Plugged in and charging")
                    }
                } else {
                    statusComponents.append("Plugged in but not charging")
                }
            }
        } else if !bbVehicle.isElectric, let gasRange = bbVehicle.gasRange {
            statusComponents.append("Fuel: \(Int(gasRange.percentage))%")
        }

        // Climate status
        if let climateStatus = bbVehicle.climateStatus {
            if climateStatus.airControlOn {
                statusComponents.append("Climate control is on")
                statusComponents.append("Target temperature: \(climateStatus.temperature.value)°")
            } else {
                statusComponents.append("Climate control is off")
            }
        }

        // Last updated info
        if let lastUpdated = bbVehicle.lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let timeText = formatter.localizedString(for: lastUpdated, relativeTo: Date())
            statusComponents.append("Last updated \(timeText)")
        }

        let statusText = statusComponents.joined(separator: "\n")
        return .result(dialog: IntentDialog(stringLiteral: statusText))
    }
}

// MARK: - Helper Functions

@MainActor
private func performVehicleActionWithVin(
    _ vin: String,
    action: @escaping (BBVehicle, BBAccount, ModelContext) async throws -> Void,
) async throws {
    let modelContainer = try createSharedModelContainer()
    let context = ModelContext(modelContainer)

    let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

    guard let vehicle = vehicles.first(where: { $0.vin == vin }),
          let account = vehicle.account
    else {
        throw IntentError.vehicleNotFound
    }

    try await action(vehicle, account, context)
}

public func refreshWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
}

private func sendNotification(title: String, body: String) async {
    #if canImport(UserNotifications) && !os(watchOS)
        // Check if notifications are enabled in settings
        let notificationsEnabled = await MainActor.run {
            AppSettings.shared.notificationsEnabled
        }

        guard notificationsEnabled else {
            print("ℹ️ [Notifications] Notifications disabled in settings")
            return
        }

        do {
            let center = UNUserNotificationCenter.current()

            // Check permission first
            let notificationSettings = await center.notificationSettings()
            guard notificationSettings.authorizationStatus == .authorized else {
                print("❌ [Notifications] Not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil,
            )

            try await center.add(request)
            print("✅ [Notifications] Sent: \(title)")
        } catch {
            print("❌ [Notifications] Failed to send: \(error)")
        }
    #else
        print("ℹ️ [Notifications] Notifications not available on this platform")
    #endif
}

// MARK: - Control Center Configuration Intents

struct LockVehicleControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Lock Vehicle"
    static var description = IntentDescription("Lock your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to lock"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
            try await account.lockVehicle(bbVehicle, modelContext: context)
        }

        await sendNotification(title: "Lock Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
        return .result(dialog: "Lock request sent to \(vehicleName)")
    }
}

struct UnlockVehicleControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Unlock Vehicle"
    static var description = IntentDescription("Unlock your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to unlock",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
            try await account.unlockVehicle(bbVehicle, modelContext: context)
        }

        // Send local notification for feedback
        await sendNotification(title: "Unlock Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
        return .result(dialog: "Unlock request sent to \(vehicleName)")
    }
}

struct StartClimateControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Start Climate Control"
    static var description = IntentDescription("Start climate control for your vehicle")
    static var openAppWhenRun: Bool = true  // Must open app to start Live Activity

    @Parameter(title: "Preset", description: "The climate control preset to use")
    var preset: ClimatePresetEntity?

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard let preset else {
            throw IntentError.noPresetSelected
        }

        // Build URL with all parameters for the main app to handle
        // The main app will start the Live Activity and send the command
        var components = URLComponents()
        components.scheme = "betterblue"
        components.host = "startClimate"
        components.path = "/\(preset.vehicleVin)"
        components.queryItems = [
            URLQueryItem(name: "presetId", value: preset.id.uuidString),
            URLQueryItem(name: "presetName", value: preset.presetName),
            URLQueryItem(name: "presetIcon", value: preset.presetIcon),
        ]

        guard let url = components.url else {
            throw IntentError.vehicleNotFound
        }

        print("🚗 [StartClimateControlIntent] Opening app with URL: \(url)")
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct StopClimateControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Stop Climate Control"
    static var description = IntentDescription("Stop climate control for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop climate control",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
            try await account.stopClimate(bbVehicle, modelContext: context)
        }

        await sendNotification(title: "Climate Stop Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
        return .result(dialog: "Climate stop request sent to \(vehicleName)")
    }
}

struct StartChargeControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Start Charging"
    static var description = IntentDescription("Start charging for your vehicle")
    static var openAppWhenRun: Bool = true  // Must open app to start Live Activity

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to start charging",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }

        // Build URL for the main app to handle
        // The main app will start the Live Activity and send the command
        guard let url = URL(string: "betterblue://startCharge/\(vehicle.vin)") else {
            throw IntentError.vehicleNotFound
        }

        print("🔌 [StartChargeControlIntent] Opening app with URL: \(url)")
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct StopChargeControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Stop Charging"
    static var description = IntentDescription("Stop charging for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop charging",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
            try await account.stopCharge(bbVehicle, modelContext: context)
        }

        await sendNotification(title: "Charge Stop Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
        return .result(dialog: "Charge stop request sent to \(vehicleName)")
    }
}

// MARK: - Intent Errors

enum IntentError: Swift.Error, LocalizedError {
    case vehicleNotFound
    case accountNotFound
    case refreshFailed(String)
    case noVehicleSelected
    case noPresetSelected

    var errorDescription: String? {
        switch self {
        case .vehicleNotFound:
            "Vehicle not found"
        case .accountNotFound:
            "Account not found for vehicle"
        case let .refreshFailed(message):
            "Failed to refresh vehicle status: \(message)"
        case .noVehicleSelected:
            "Please edit this control and select a vehicle before using it"
        case .noPresetSelected:
            "Please select a climate preset"
        }
    }
}
