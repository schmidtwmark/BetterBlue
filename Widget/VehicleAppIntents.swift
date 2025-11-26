//
//  VehicleAppIntents.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import UserNotifications
import WidgetKit

// MARK: - Vehicle Action Intents

struct LockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Vehicle"
    static var description = IntentDescription("Lock your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to lock")
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let vehicle else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle provided"],
                )
            }
            let targetVin = vehicle.vin
            let vehicleName = vehicle.displayName

            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.lockVehicle(bbVehicle, modelContext: context)
            }

            await sendNotification(title: "Lock Request Sent", body: "Command sent to \(vehicleName)")

            WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
            return .result(dialog: "Lock request sent to \(vehicleName)")
        } catch {
            throw error
        }
    }
}

struct UnlockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock Vehicle"
    static var description = IntentDescription("Unlock your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to unlock")
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let vehicle else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle provided"],
                )
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
        } catch {
            throw error
        }
    }
}

struct StartClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Climate Control"
    static var description = IntentDescription("Start climate control for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset", description: "The vehicle and preset to use")
    var preset: ClimatePresetEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let targetVin: String
            let vehicleName: String
            let presetId: UUID?

            if let preset {
                targetVin = preset.vehicleVin
                vehicleName = preset.vehicleName
                presetId = preset.id
            } else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle or preset provided"],
                )
            }

            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                var options: ClimateOptions? = nil
                if let presetId {
                    let predicate = #Predicate<ClimatePreset> { $0.id == presetId }
                    let descriptor = FetchDescriptor(predicate: predicate)
                    if let preset = try? context.fetch(descriptor).first {
                        options = preset.climateOptions
                    }
                }
                print("Starting climate from intent, options: \(bbVehicle.safeClimatePresets)")
                try await account.startClimate(bbVehicle, options: options, modelContext: context)
            }

            var dialog: IntentDialog
            if let preset = preset {
                dialog = "Climate start request sent to \(vehicleName) with preset \(preset.presetName)"
                await sendNotification(title: "Climate Start Request Sent", body: "Command sent to \(vehicleName) with preset \(preset.presetName)")
            } else {
                dialog = "Climate start request sent to \(vehicleName)"
                await sendNotification(title: "Climate Start Request Sent", body: "Command sent to \(vehicleName)")
            }

            WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
            return .result(dialog: dialog)
        } catch {
            throw error
        }
    }
}

struct StopClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Climate Control"
    static var description = IntentDescription("Stop climate control for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to stop climate control")
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let vehicle else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle provided"],
                )
            }
            let targetVin = vehicle.vin
            let vehicleName = vehicle.displayName

            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.stopClimate(bbVehicle, modelContext: context)
            }

            await sendNotification(title: "Climate Stop Request Sent", body: "Command sent to \(vehicleName)")

            WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
            return .result(dialog: "Climate stop request sent to \(vehicleName)")
        } catch {
            throw error
        }
    }
}

struct StartChargeIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Charging"
    static var description = IntentDescription("Start charging for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to start charging")
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let vehicle else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle provided"],
                )
            }
            let targetVin = vehicle.vin
            let vehicleName = vehicle.displayName

            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.startCharge(bbVehicle, modelContext: context)
            }

            await sendNotification(title: "Charge Request Sent", body: "Command sent to \(vehicleName)")

            WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
            return .result(dialog: "Charge request sent to \(vehicleName)")
        } catch {
            throw error
        }
    }
}

struct StopChargeIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Charging"
    static var description = IntentDescription("Stop charging for your vehicle")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to stop charging")
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            guard let vehicle else {
                throw NSError(
                    domain: "com.betterblue.app",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No vehicle provided"],
                )
            }
            let targetVin = vehicle.vin
            let vehicleName = vehicle.displayName

            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.stopCharge(bbVehicle, modelContext: context)
            }

            await sendNotification(title: "Charge Stop Request Sent", body: "Command sent to \(vehicleName)")

            WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")
            return .result(dialog: "Charge stop request sent to \(vehicleName)")
        } catch {
            throw error
        }
    }
}

// MARK: - Siri Shortcut Intents

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
        let updatedVehicle = VehicleEntity(from: bbVehicle, with: unit)

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
    static var title: LocalizedStringResource = "Lock Vehicle (ControlKit)"
    static var description = IntentDescription("Lock your vehicle")

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to lock"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vehicle = vehicle else {
            throw IntentError.noVehicleSelected
        }
        let lockIntent = LockVehicleIntent()
        lockIntent.vehicle = vehicle
        _ = try await lockIntent.perform()
        return .result()
    }
}

struct UnlockVehicleControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Unlock Vehicle (ControlKit)"
    static var description = IntentDescription("Unlock your vehicle")

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to unlock",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vehicle = vehicle else {
            throw IntentError.noVehicleSelected
        }
        let unlockIntent = UnlockVehicleIntent()
        unlockIntent.vehicle = vehicle
        _ = try await unlockIntent.perform()
        return .result()
    }
}

struct StartClimateControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Start Climate Control (ControlKit)"
    static var description = IntentDescription("Start climate control for your vehicle")

    @Parameter(title: "Preset", description: "The climate control preset to use")
    var preset: ClimatePresetEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start climate with \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let startIntent = StartClimateIntent()
        startIntent.preset = preset
        _ = try await startIntent.perform()
        return .result()
    }
}

struct StopClimateControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Stop Climate Control (ControlKit)"
    static var description = IntentDescription("Stop climate control for your vehicle")

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop climate control",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vehicle = vehicle else {
            throw IntentError.noVehicleSelected
        }
        let stopIntent = StopClimateIntent()
        stopIntent.vehicle = vehicle
        _ = try await stopIntent.perform()
        return .result()
    }
}

struct StartChargeControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Start Charging (ControlKit)"
    static var description = IntentDescription("Start charging for your vehicle")

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to start charging",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vehicle = vehicle else {
            throw IntentError.noVehicleSelected
        }
        let startIntent = StartChargeIntent()
        startIntent.vehicle = vehicle
        _ = try await startIntent.perform()
        return .result()
    }
}

struct StopChargeControlIntent: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Stop Charging (ControlKit)"
    static var description = IntentDescription("Stop charging for your vehicle")

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop charging",
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vehicle = vehicle else {
            throw IntentError.noVehicleSelected
        }
        let stopIntent = StopChargeIntent()
        stopIntent.vehicle = vehicle
        _ = try await stopIntent.perform()
        return .result()
    }
}

// MARK: - Intent Errors

enum IntentError: Swift.Error, LocalizedError {
    case vehicleNotFound
    case accountNotFound
    case refreshFailed(String)
    case noVehicleSelected

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
        }
    }
}
