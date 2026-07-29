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
            .none: DisplayRepresentation(title: "None")
        ]
    }

    public static var allCases: [LiveActivityType] {
        [.climate, .charging, .none]
    }
}

// MARK: - Live Activity Intents

struct StopLiveActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Live Activity"
    static let description = IntentDescription("Stop the current activity (climate or charging)")

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
        BBLogger.info(.intent, "StopLiveActivityIntent: Starting for VIN: \(vin), type: \(activityType)")

        // Find the existing activity
        let activities = Activity<VehicleActivityAttributes>.activities
        guard let existingActivity = activities.first(where: { $0.attributes.vin == vin }) else {
            BBLogger.error(.intent, "StopLiveActivityIntent: No activity found for VIN: \(vin)")
            return .result()
        }

        // Fetch the vehicle and account
        let modelContainer = try createSharedModelContainer(enableCloudKit: false)
        let context = ModelContext(modelContainer)
        let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        guard let bbVehicle = vehicles.first(where: { $0.vin == vin }),
              let account = bbVehicle.account
        else {
            BBLogger.error(.intent, "StopLiveActivityIntent: Vehicle or account not found for VIN: \(vin)")
            return .result()
        }

        // Send the appropriate stop command
        do {
            switch activityType {
            case .climate:
                BBLogger.info(.intent, "StopLiveActivityIntent: Stopping climate...")
                try await account.stopClimate(bbVehicle, modelContext: context)
            case .charging:
                BBLogger.info(.intent, "StopLiveActivityIntent: Stopping charge...")
                try await account.stopCharge(bbVehicle, modelContext: context)
            case .debug:
                BBLogger.info(.intent, "StopLiveActivityIntent: Stopping debug activity...")
                bbVehicle.debugLiveActivity = false
                try context.save()
            case .none:
                BBLogger.warning(.intent, "StopLiveActivityIntent: Activity type is .none, nothing to stop")
            }

            // End the Live Activity
            nonisolated(unsafe) let activity = existingActivity
            await activity.end(nil, dismissalPolicy: .immediate)
            BBLogger.info(.intent, "StopLiveActivityIntent: Activity ended successfully")

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
            BBLogger.error(.intent, "StopLiveActivityIntent: Error: \(error)")
        }

        return .result()
        #else
        return .result()
        #endif
    }
}

struct RefreshVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Vehicle Status"
    static let description = IntentDescription("Refresh the status of your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to refresh")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VehicleEntity> & ProvidesDialog {
        let modelContainer = try createSharedModelContainer(enableCloudKit: false)
        let context = ModelContext(modelContainer)

        let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        guard let bbVehicle = vehicles.first(where: { $0.vin == vehicle.vin }),
              let account = bbVehicle.account
        else {
            throw IntentError.vehicleNotFound
        }

        // Explicit user-invoked refresh intent → force real-time poll
        // AND a vehicle list refresh so a Siri / Control Center refresh
        // catches any metadata drift just like the in-app refresh
        // button does.
        try await account.fetchAndUpdateVehicleStatus(
            for: bbVehicle,
            modelContext: context,
            cached: false,
            forceVehicleListRefresh: true
        )

        let unit = AppSettings.liveDistanceUnit()
        let allPresets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        let updatedVehicle = VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)

        WidgetCenter.shared.reloadAllTimelines()

        // Return the freshly-populated entity so a Shortcut can chain
        // "Refresh Vehicle Status → check isPluggedIn → notify."
        // The dialog still describes the result for Siri.
        return .result(
            value: updatedVehicle,
            dialog: "\(updatedVehicle.displayName) status updated. \(updatedVehicle.rangeText)"
        )
    }
}

struct GetVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Status"
    static let description = IntentDescription("Get the current status of your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "The vehicle to check")
    var vehicle: VehicleEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VehicleEntity> & ProvidesDialog {
        let modelContainer = try createSharedModelContainer(enableCloudKit: false)
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
        if bbVehicle.fuelType.hasElectricCapability, let evStatus = bbVehicle.evStatus {
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
        } else if bbVehicle.fuelType == .gas, let gasRange = bbVehicle.gasRange {
            statusComponents.append("Fuel: \(Int(gasRange.percentage))%")
        }

        // Climate status
        if let climateStatus = bbVehicle.climateStatus {
            if climateStatus.airControlOn {
                statusComponents.append("Climate control is on")
                if climateStatus.temperature.isPlausibleForDisplay {
                    let tempString = climateStatus.temperature.units.format(
                        climateStatus.temperature.value,
                        to: AppSettings.liveTemperatureUnit()
                    )
                    statusComponents.append("Target temperature: \(tempString)")
                }
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
        // Build the freshly-populated entity so Shortcuts can read
        // booleans (isPluggedIn, isCharging, isLocked, isClimateOn)
        // instead of having to parse the status string. The dialog
        // still describes the result for Siri voice replies.
        let unit = AppSettings.liveDistanceUnit()
        let allPresets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        let statusEntity = VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)
        return .result(
            value: statusEntity,
            dialog: IntentDialog(stringLiteral: statusText)
        )
    }
}

// MARK: - Property accessor intents
//
// These intents are first-class entries in the Shortcuts action
// library. Each takes a `VehicleEntity` parameter and returns a
// bare value (`Bool`, `Int`, `String`) so users don't have to
// discover the "Get Details of Vehicle" auto-generated action or
// learn the magic-variable property-picker UX — they can just
// search "Is Vehicle Plugged In" and add it directly.
//
// None of these refresh the vehicle status — they read the
// SwiftData-cached value. Chain `Refresh Vehicle Status` before
// them if you need a guaranteed-fresh reading.

private func fetchBBVehicle(forVin vin: String, context: ModelContext) throws -> BBVehicle {
    let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
    guard let bbVehicle = vehicles.first(where: { $0.vin == vin }) else {
        throw IntentError.vehicleNotFound
    }
    return bbVehicle
}

struct IsVehiclePluggedInIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Vehicle Plugged In"
    static let description = IntentDescription("Returns true if the vehicle's charging cable is connected.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        return .result(value: bbVehicle.evStatus?.pluggedIn ?? false)
    }
}

struct IsVehicleChargingIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Vehicle Charging"
    static let description = IntentDescription("Returns true if the vehicle is actively drawing power.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        return .result(value: bbVehicle.evStatus?.charging ?? false)
    }
}

struct IsVehicleLockedIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Vehicle Locked"
    static let description = IntentDescription("Returns true if the vehicle's doors are locked.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        return .result(value: bbVehicle.lockStatus == .locked)
    }
}

struct IsClimateOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Climate Control On"
    static let description = IntentDescription("Returns true if climate control is currently running.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        return .result(value: bbVehicle.climateStatus?.airControlOn ?? false)
    }
}

struct GetBatteryPercentageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Battery Percentage"
    static let description = IntentDescription("Returns the EV battery percentage (0–100), or the fuel level for ICE vehicles.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        // EV battery first; fall back to gas tank percentage for ICE.
        if bbVehicle.fuelType.hasElectricCapability, let ev = bbVehicle.evStatus {
            return .result(value: Int(ev.evRange.percentage.rounded()))
        }
        if let gas = bbVehicle.gasRange {
            return .result(value: Int(gas.percentage.rounded()))
        }
        return .result(value: 0)
    }
}

struct GetVehicleRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Range"
    static let description = IntentDescription("Returns the formatted remaining range (e.g. \"218 mi\").")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Just re-uses the rangeText we already formatted on the
        // entity at fetch time — no need to round-trip through the
        // container.
        return .result(value: vehicle.rangeText)
    }
}

struct GetChargeTimeRemainingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Charge Time Remaining"
    static let description = IntentDescription("Returns the minutes until the charge target is reached. Zero if not charging.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle")
    var vehicle: VehicleEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let context = ModelContext(try createSharedModelContainer(enableCloudKit: false))
        let bbVehicle = try fetchBBVehicle(forVin: vehicle.vin, context: context)
        guard let ev = bbVehicle.evStatus, ev.charging else { return .result(value: 0) }
        let minutes = Int(ev.chargeTime.components.seconds / 60)
        return .result(value: max(0, minutes))
    }
}

// MARK: - Helper Functions

@MainActor
private func performVehicleActionWithVin(
    _ vin: String,
    action: @escaping @MainActor (BBVehicle, BBAccount, ModelContext) async throws -> Void,
) async throws {
    let modelContainer = try createSharedModelContainer(enableCloudKit: false)
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
            BBLogger.info(.push, "Notifications: Notifications disabled in settings")
            return
        }

        do {
            let center = UNUserNotificationCenter.current()

            // Check permission first
            let notificationSettings = await center.notificationSettings()
            guard notificationSettings.authorizationStatus == .authorized else {
                BBLogger.error(.push, "Notifications: Not authorized")
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
            BBLogger.info(.push, "Notifications: Sent: \(title)")
        } catch {
            BBLogger.error(.push, "Notifications: Failed to send: \(error)")
        }
    #else
        BBLogger.info(.push, "Notifications: Notifications not available on this platform")
    #endif
}

// MARK: - Control Center Configuration Intents

struct LockVehicleControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Lock Vehicle"
    static let description = IntentDescription("Lock your vehicle")
    static let openAppWhenRun: Bool = false

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

        // Optimistically surface the request on the widget right away,
        // before the (possibly slow) command round-trips. Claiming the slot
        // also collapses a duplicate delivery of this intent (#94).
        guard WidgetCommandStatus.beginCommand("Lock", vin: targetVin) else {
            BBLogger.info(.intent, "LockVehicleIntent: duplicate lock for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Lock request already sent to \(vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.lockVehicle(bbVehicle, modelContext: context)
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Lock Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Lock request sent to \(vehicleName)")
    }
}

struct UnlockVehicleControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Unlock Vehicle"
    static let description = IntentDescription("Unlock your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to unlock"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        guard WidgetCommandStatus.beginCommand("Unlock", vin: targetVin) else {
            BBLogger.info(.intent, "UnlockVehicleIntent: duplicate unlock for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Unlock request already sent to \(vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.unlockVehicle(bbVehicle, modelContext: context)
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Unlock Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Unlock request sent to \(vehicleName)")
    }
}

struct StartClimateControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Start Climate Control"
    static let description = IntentDescription("Start climate control for your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Preset", description: "The climate control preset to use")
    var preset: ClimatePresetEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let preset else {
            throw IntentError.noPresetSelected
        }

        let presetId = preset.id
        let presetName = preset.presetName
        let presetIcon = preset.presetIcon
        let targetVin = preset.vehicleVin

        guard WidgetCommandStatus.beginCommand("Start Climate", vin: targetVin) else {
            BBLogger.info(.intent, "StartClimateIntent: duplicate start for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Climate start request already sent to \(preset.vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                if let climatePreset = bbVehicle.safeClimatePresets.first(where: { $0.id == presetId }) {
                    try await account.startClimate(
                        bbVehicle,
                        options: climatePreset.climateOptions,
                        modelContext: context,
                        presetName: presetName,
                        presetIcon: presetIcon
                    )
                } else {
                    try await account.startClimate(
                        bbVehicle,
                        modelContext: context,
                        presetName: presetName,
                        presetIcon: presetIcon
                    )
                }
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Climate Start Request Sent", body: "Command sent to \(preset.vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Climate start request sent to \(preset.vehicleName)")
    }
}

struct StopClimateControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Stop Climate Control"
    static let description = IntentDescription("Stop climate control for your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop climate control"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        guard WidgetCommandStatus.beginCommand("Stop Climate", vin: targetVin) else {
            BBLogger.info(.intent, "StopClimateIntent: duplicate stop for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Climate stop request already sent to \(vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.stopClimate(bbVehicle, modelContext: context)
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Climate Stop Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Climate stop request sent to \(vehicleName)")
    }
}

struct StartChargeControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Start Charging"
    static let description = IntentDescription("Start charging for your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to start charging"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        guard WidgetCommandStatus.beginCommand("Start Charge", vin: targetVin) else {
            BBLogger.info(.intent, "StartChargeIntent: duplicate start for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Charge start request already sent to \(vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.startCharge(bbVehicle, modelContext: context)
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Charge Start Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Charge start request sent to \(vehicleName)")
    }
}

struct StopChargeControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Stop Charging"
    static let description = IntentDescription("Stop charging for your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to stop charging"
    )
    var vehicle: VehicleEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vehicle else {
            throw IntentError.noVehicleSelected
        }
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        guard WidgetCommandStatus.beginCommand("Stop Charge", vin: targetVin) else {
            BBLogger.info(.intent, "StopChargeIntent: duplicate stop for \(targetVin.prefix(8)), ignoring")
            return .result(dialog: "Charge stop request already sent to \(vehicleName)")
        }
        WidgetCenter.shared.reloadAllTimelines()

        do {
            try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
                try await account.stopCharge(bbVehicle, modelContext: context)
            }
        } catch {
            WidgetCommandStatus.clear(vin: targetVin)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }

        await sendNotification(title: "Charge Stop Request Sent", body: "Command sent to \(vehicleName)")

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Charge stop request sent to \(vehicleName)")
    }
}

struct SetChargeLimitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Limits"
    static let description = IntentDescription("Set the AC and DC charge limits for your vehicle")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Vehicle",
        description: "Select the vehicle to set charge limits"
    )
    var vehicle: VehicleEntity

    @Parameter(
        title: "AC Charge Limit",
        description: "The charge limit for AC charging (Level 1/2)",
        controlStyle: .stepper,
        inclusiveRange: (50, 100)
    )
    var acLimit: Int

    @Parameter(
        title: "DC Charge Limit",
        description: "The charge limit for DC fast charging",
        controlStyle: .stepper,
        inclusiveRange: (50, 100)
    )
    var dcLimit: Int

    init() {}

    init(vehicle: VehicleEntity, acLimit: Int, dcLimit: Int) {
        self.vehicle = vehicle
        self.acLimit = acLimit
        self.dcLimit = dcLimit
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let targetVin = vehicle.vin
        let vehicleName = vehicle.displayName

        try await performVehicleActionWithVin(targetVin) { bbVehicle, account, context in
            try await account.setTargetSOC(
                bbVehicle,
                acLevel: acLimit,
                dcLevel: dcLimit,
                modelContext: context
            )
        }

        await sendNotification(
            title: "Charge Limits Set",
            body: "AC: \(acLimit)%, DC: \(dcLimit)% for \(vehicleName)"
        )

        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Charge limits set to AC: \(acLimit)%, DC: \(dcLimit)% for \(vehicleName)")
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
