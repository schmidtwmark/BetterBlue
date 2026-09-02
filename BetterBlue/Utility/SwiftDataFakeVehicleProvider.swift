//
//  SwiftDataFakeVehicleProvider.swift
//  BetterBlue
//
//  SwiftData implementation of FakeVehicleProvider
//

import BetterBlueKit
import Foundation
import SwiftData

// MARK: - Debug Configuration Model

struct BBDebugConfiguration: Codable {
    var id: UUID = .init()

    // Debug failure modes
    var shouldFailCredentialValidation: Bool = false
    var shouldFailLogin: Bool = false
    var shouldFailVehicleFetch: Bool = false
    var shouldFailStatusFetch: Bool = false
    var shouldFailPinValidation: Bool = false
    /// The vehicle refuses the capture request outright.
    var shouldFailSurroundView: Bool = false
    /// The request is accepted but the images never arrive — the only way
    /// to reach the view's six-minute give-up path without waiting out a
    /// real failure.
    var shouldFailSurroundViewUpload: Bool = false

    // Command-specific failures
    var shouldFailLock: Bool = false
    var shouldFailUnlock: Bool = false
    var shouldFailStartClimate: Bool = false
    var shouldFailStopClimate: Bool = false
    var shouldFailStartCharge: Bool = false
    var shouldFailStopCharge: Bool = false

    // Custom error messages
    var customCredentialErrorMessage: String = "Invalid credentials"
    var customPinErrorMessage: String = "Invalid PIN"

    init() {}

    /// Written by hand on purpose.
    ///
    /// This struct is persisted as a Codable attribute on `BBVehicle` and
    /// synced through iCloud, so configurations written by older builds
    /// outlive the code that wrote them. Swift's synthesized decoder does
    /// NOT fall back to a property's default value for a missing key — it
    /// throws `keyNotFound` — so adding a single field here would
    /// invalidate every debug configuration already in the store and
    /// silently wipe the toggles a user had set. `decodeIfPresent`
    /// throughout makes new fields additive instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        shouldFailCredentialValidation = try flag(.shouldFailCredentialValidation)
        shouldFailLogin = try flag(.shouldFailLogin)
        shouldFailVehicleFetch = try flag(.shouldFailVehicleFetch)
        shouldFailStatusFetch = try flag(.shouldFailStatusFetch)
        shouldFailPinValidation = try flag(.shouldFailPinValidation)
        shouldFailSurroundView = try flag(.shouldFailSurroundView)
        shouldFailSurroundViewUpload = try flag(.shouldFailSurroundViewUpload)

        shouldFailLock = try flag(.shouldFailLock)
        shouldFailUnlock = try flag(.shouldFailUnlock)
        shouldFailStartClimate = try flag(.shouldFailStartClimate)
        shouldFailStopClimate = try flag(.shouldFailStopClimate)
        shouldFailStartCharge = try flag(.shouldFailStartCharge)
        shouldFailStopCharge = try flag(.shouldFailStopCharge)

        customCredentialErrorMessage = try container
            .decodeIfPresent(String.self, forKey: .customCredentialErrorMessage) ?? "Invalid credentials"
        customPinErrorMessage = try container
            .decodeIfPresent(String.self, forKey: .customPinErrorMessage) ?? "Invalid PIN"
    }

    func shouldFailCommand(_ command: VehicleCommand) -> Bool {
        switch command {
        case .lock:
            shouldFailLock
        case .unlock:
            shouldFailUnlock
        case .startClimate:
            shouldFailStartClimate
        case .stopClimate:
            shouldFailStopClimate
        case .startCharge:
            shouldFailStartCharge
        case .stopCharge:
            shouldFailStopCharge
        case .setTargetSOC:
            false
        }
    }
}

// MARK: - SwiftData Vehicle Provider

@MainActor
public class SwiftDataFakeVehicleProvider: FakeVehicleProvider {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        BBLogger.info(.fakeAPI, "SwiftDataFakeVehicleProvider: Initialized with SwiftData context")
    }

    public func getFakeVehicles(for _: String, accountId: UUID) async throws -> [Vehicle] {
        // Fetch existing fake vehicles for this account from SwiftData
        let accountPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: accountPredicate)
        let existingVehicles = try modelContext.fetch(descriptor)

        BBLogger.debug(.fakeAPI, "SwiftDataFakeVehicleProvider: Found \(existingVehicles.count) existing fake vehicles for account")
        return existingVehicles.map { $0.toVehicle() }
    }

    public func getVehicleStatus(for vin: String, accountId: UUID) async throws -> VehicleStatus {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId) else {
            throw APIError.logError("Fake vehicle not found: \(vin)", apiName: "FakeAPI")
        }

        // Update lastUpdated to simulate a fresh fetch from the server
        bbVehicle.lastUpdated = Date()
        bbVehicle.syncDate = Date()
        try? modelContext.save()

        return createVehicleStatus(from: bbVehicle)
    }

    public func executeCommand(_ command: VehicleCommand, for vin: String, accountId: UUID) async throws {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId) else {
            throw APIError.logError("Fake vehicle not found for command: \(vin)", apiName: "FakeAPI")
        }

        // Update the BBVehicle directly based on the command
        switch command {
        case .lock:
            BBLogger.info(.fakeAPI, "FakeAPI: Locking fake vehicle '\(bbVehicle.vin)'")
            bbVehicle.lockStatus = .locked
        case .unlock:
            BBLogger.info(.fakeAPI, "FakeAPI: Unlocking fake vehicle '\(bbVehicle.vin)'")
            bbVehicle.lockStatus = .unlocked
        case let .startClimate(options):
            BBLogger.info(.fakeAPI, "FakeAPI: Starting climate for fake vehicle '\(bbVehicle.vin)' at \(options.temperature.value)°")
            bbVehicle.climateStatus = VehicleStatus.ClimateStatus(
                defrostOn: options.defrost,
                airControlOn: options.climate,
                steeringWheelHeatingOn: options.steeringWheel != 0,
                temperature: options.temperature,
            )
        case .stopClimate:
            BBLogger.info(.fakeAPI, "FakeAPI: Stopping climate for fake vehicle '\(bbVehicle.vin)'")
            if let currentClimate = bbVehicle.climateStatus {
                bbVehicle.climateStatus = VehicleStatus.ClimateStatus(
                    defrostOn: false,
                    airControlOn: false,
                    steeringWheelHeatingOn: false,
                    temperature: currentClimate.temperature,
                )
            }
        case .startCharge:
            BBLogger.info(.fakeAPI, "FakeAPI: Starting charge for fake vehicle '\(bbVehicle.vin)'")
            if let evStatus = bbVehicle.evStatus {
                let batteryPercentage = evStatus.evRange.percentage
                // Calculate reasonable charge time: assume 50 kW charging speed, ~1% per minute
                let remainingPercentage = 100.0 - batteryPercentage
                let chargeTimeMinutes = Int64(remainingPercentage * 1.5) // ~1.5 minutes per %

                bbVehicle.evStatus = VehicleStatus.EVStatus(
                    charging: true,
                    chargeSpeed: 50.0,
                    evRange: evStatus.evRange,
                    plugType: evStatus.plugType != .unplugged ? evStatus.plugType : .acCharger,
                    chargeTime: .seconds(chargeTimeMinutes * 60),
                    targetSocAC: evStatus.targetSocAC,
                    targetSocDC: evStatus.targetSocDC
                )
            }
        case .stopCharge:
            BBLogger.info(.fakeAPI, "FakeAPI: Stopping charge for fake vehicle '\(bbVehicle.vin)'")
            if let evStatus = bbVehicle.evStatus {
                bbVehicle.evStatus = VehicleStatus.EVStatus(
                    charging: false,
                    chargeSpeed: 0.0,
                    evRange: evStatus.evRange,
                    plugType: evStatus.plugType,
                    chargeTime: .seconds(0),
                    targetSocAC: evStatus.targetSocAC,
                    targetSocDC: evStatus.targetSocDC
                )
            }
        case let .setTargetSOC(acLevel, dcLevel):
            BBLogger.info(.fakeAPI, "FakeAPI: Setting target SOC for fake vehicle '\(bbVehicle.vin)' - AC: \(acLevel)%, DC: \(dcLevel)%")
            if let evStatus = bbVehicle.evStatus {
                bbVehicle.evStatus = VehicleStatus.EVStatus(
                    charging: evStatus.charging,
                    chargeSpeed: evStatus.chargeSpeed,
                    evRange: evStatus.evRange,
                    plugType: evStatus.plugType,
                    chargeTime: evStatus.chargeTime,
                    targetSocAC: Double(acLevel),
                    targetSocDC: Double(dcLevel)
                )
            }
        }

        bbVehicle.lastUpdated = Date()

        // Save changes to SwiftData
        try modelContext.save()
        BBLogger.debug(.fakeAPI, "SwiftDataFakeVehicleProvider: Saved vehicle status changes to SwiftData")
    }

    public func shouldFailCredentialValidation(accountId: UUID) async throws -> Bool {
        let accountPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: accountPredicate)
        let vehicles = try modelContext.fetch(descriptor)

        return vehicles.compactMap(\.debugConfiguration).contains { $0.shouldFailCredentialValidation }
    }

    public func shouldFailLogin(accountId: UUID) async throws -> Bool {
        let accountPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: accountPredicate)
        let vehicles = try modelContext.fetch(descriptor)

        return vehicles.compactMap(\.debugConfiguration).contains { $0.shouldFailLogin }
    }

    public func shouldFailVehicleFetch(accountId: UUID) async throws -> Bool {
        let accountPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: accountPredicate)
        let vehicles = try modelContext.fetch(descriptor)

        return vehicles.compactMap(\.debugConfiguration).contains { $0.shouldFailVehicleFetch }
    }

    public func shouldFailStatusFetch(for vin: String, accountId: UUID) async throws -> Bool {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId),
              let debugConfig = bbVehicle.debugConfiguration
        else {
            return false
        }
        return debugConfig.shouldFailStatusFetch
    }

    public func shouldFailPinValidation(for vin: String, accountId: UUID) async throws -> Bool {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId),
              let debugConfig = bbVehicle.debugConfiguration
        else {
            return false
        }
        return debugConfig.shouldFailPinValidation
    }

    public func shouldFailCommand(_ command: VehicleCommand, for vin: String, accountId: UUID) async throws -> Bool {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId),
              let debugConfig = bbVehicle.debugConfiguration
        else {
            return false
        }
        return debugConfig.shouldFailCommand(command)
    }

    // MARK: - Surround View

    public func requestSurroundViewCapture(for vin: String, accountId: UUID) async throws {
        guard getBBVehicle(for: vin, accountId: accountId) != nil else {
            throw APIError.logError("Fake vehicle not found for surround view: \(vin)", apiName: "FakeAPI")
        }
        try throwIfSurroundViewDisabled(for: vin, accountId: accountId)

        // Both real Canada endpoints post the PIN, so a PIN refusal is
        // the most faithful failure to simulate here.
        if try await shouldFailPinValidation(for: vin, accountId: accountId) {
            throw APIError.invalidPin(
                try await getCustomPinErrorMessage(for: vin, accountId: accountId),
                apiName: "FakeAPI"
            )
        }

        let config = getBBVehicle(for: vin, accountId: accountId)?.debugConfiguration
        FakeSurroundViewStore.shared.requestCapture(
            vin: vin,
            neverCompletes: config?.shouldFailSurroundViewUpload ?? false
        )
    }

    public func getSurroundViewCaptures(for vin: String, accountId: UUID) async throws -> [SurroundViewCapture] {
        guard getBBVehicle(for: vin, accountId: accountId) != nil else {
            throw APIError.logError("Fake vehicle not found for surround view: \(vin)", apiName: "FakeAPI")
        }
        try throwIfSurroundViewDisabled(for: vin, accountId: accountId)

        return FakeSurroundViewStore.shared.captures(vin: vin)
    }

    /// Honors the debug toggle so the view's error path can be exercised
    /// without a real vehicle refusing the request.
    private func throwIfSurroundViewDisabled(for vin: String, accountId: UUID) throws {
        guard let config = getBBVehicle(for: vin, accountId: accountId)?.debugConfiguration,
              config.shouldFailSurroundView else {
            return
        }
        // Typed like the real refusal (Hyundai's BLODS 502) so fake mode
        // exercises the same "no cameras on this vehicle" UI state.
        throw APIError.featureNotSupported(
            "Your vehicle doesn't support surround view — it doesn't have the surround-view camera system.",
            apiName: "FakeAPI"
        )
    }

    public func getCustomCredentialErrorMessage(accountId: UUID) async throws -> String {
        let accountPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: accountPredicate)
        let vehicles = try modelContext.fetch(descriptor)

        return vehicles.compactMap(\.debugConfiguration).first?.customCredentialErrorMessage ?? "Invalid credentials"
    }

    public func getCustomPinErrorMessage(for vin: String, accountId: UUID) async throws -> String {
        guard let bbVehicle = getBBVehicle(for: vin, accountId: accountId),
              let debugConfig = bbVehicle.debugConfiguration
        else {
            return "Invalid PIN"
        }
        return debugConfig.customPinErrorMessage
    }

    private func getBBVehicle(for vin: String, accountId: UUID) -> BBVehicle? {
        let vinPredicate = #Predicate<BBVehicle> { vehicle in
            vehicle.vin == vin && vehicle.accountId == accountId
        }

        let descriptor = FetchDescriptor<BBVehicle>(predicate: vinPredicate)
        return try? modelContext.fetch(descriptor).first
    }

    private func createVehicleStatus(from bbVehicle: BBVehicle) -> VehicleStatus {
        var status = VehicleStatus(
            vin: bbVehicle.vin,
            gasRange: bbVehicle.gasRange,
            evStatus: bbVehicle.evStatus,
            location: bbVehicle.location ?? VehicleStatus.Location(latitude: 0, longitude: 0),
            lockStatus: bbVehicle.lockStatus ?? .unknown,
            climateStatus: bbVehicle.climateStatus ?? VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: false,
                steeringWheelHeatingOn: false,
                temperature: Temperature(value: 70, units: .fahrenheit)
            ),
            odometer: bbVehicle.odometer,
            syncDate: bbVehicle.syncDate ?? Date(),
            battery12V: bbVehicle.battery12V,
            doorOpen: bbVehicle.doorOpen,
            trunkOpen: bbVehicle.trunkOpen,
            hoodOpen: bbVehicle.hoodOpen,
            tirePressureWarning: bbVehicle.tirePressureWarning
        )

        // Set lastUpdated separately since it's not part of the constructor
        status.lastUpdated = bbVehicle.lastUpdated ?? Date()

        return status
    }

    // Deterministic hash function that returns the same value across app launches and platforms
    private func deterministicHash(of string: String) -> Int {
        var hash = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(char)
        }
        return hash
    }
}
