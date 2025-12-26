//
//  Account.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/6/25.
//

import BetterBlueKit
import Foundation
import SwiftData

@Model
class BBAccount {
    var id: UUID = UUID()
    var username: String = ""
    var password: String = ""
    var pin: String = ""
    var brand: String = "" // Store as string, convert to/from Brand enum
    var region: String = "" // Store as string, convert to/from Region enum
    var dateCreated: Date = Date()

    @Relationship(deleteRule: .cascade) var vehicles: [BBVehicle]? = []

    var safeVehicles: [BBVehicle] {
        vehicles ?? []
    }

    @Transient
    private var api: (any APIClientProtocol)?
    @Transient
    private var authToken: AuthToken?

    init(username: String, password: String, pin: String, brand: Brand, region: Region) {
        id = UUID()
        self.username = username
        self.password = password
        self.pin = pin
        self.brand = brand.rawValue
        self.region = region.rawValue
        dateCreated = Date()
    }

    // Computed properties to convert to existing types
    var brandEnum: Brand {
        switch brand {
        case "hyundai":
            .hyundai
        case "kia":
            .kia
        case "fake":
            .fake
        default:
            .hyundai
        }
    }

    var regionEnum: Region {
        Region(rawValue: region) ?? .usa
    }
}

// MARK: - API Client Management

extension BBAccount {
    @MainActor
    func initialize(modelContext: ModelContext) async throws {
        if api == nil {
            let configuration = APIClientFactoryConfiguration(
                region: regionEnum,
                brand: brandEnum,
                username: username,
                password: password,
                pin: pin,
                accountId: id,
                modelContext: modelContext,
                logSink: HTTPLogSinkManager.shared.createLogSink()
            )
            api = createAPIClient(configuration: configuration)
        }

        if authToken == nil {
            authToken = try await api!.login()
        }
    }

    @MainActor
    private func handleInvalidVehicleSession(modelContext: ModelContext) async throws {
        print("🔄 [BBAccount] Invalid session/credentials detected, performing full re-initialization...")

        clearAPICache()
        self.api = nil
        self.authToken = nil
        try await initialize(modelContext: modelContext)

        guard let api, let authToken else {
            throw HyundaiKiaAPIError.failedRetryLogin()
        }
        let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)
        updateVehicles(vehicles: fetchedVehicles)

        print("✅ [BBAccount] Re-initialization complete")
    }

    @MainActor
    func clearAPICache() {
        if let cachedClient = api as? CachedAPIClient {
            cachedClient.clearCache()
        }
    }

    @MainActor
    var cacheStatistics: CacheStatistics? {
        (api as? CachedAPIClient)?.cacheStatistics
    }
}

// MARK: - Vehicle Data Management

extension BBAccount {
    @MainActor
    func loadVehicles(modelContext: ModelContext) async throws {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await loadVehicles(modelContext: modelContext)
        }

        do {
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)
            updateVehicles(vehicles: fetchedVehicles)
        } catch let error as HyundaiKiaAPIError where error.errorType == .invalidCredentials {
            try await handleInvalidVehicleSession(modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw HyundaiKiaAPIError.failedRetryLogin()
            }
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)
            updateVehicles(vehicles: fetchedVehicles)
        }
    }

    @MainActor
    func fetchVehicleStatus(for bbVehicle: BBVehicle, modelContext: ModelContext) async throws -> VehicleStatus {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await fetchVehicleStatus(for: bbVehicle, modelContext: modelContext)
        }

        // For Kia vehicles, ensure vehicleKey is populated by refreshing if needed
        if brandEnum == .kia && bbVehicle.vehicleKey == nil {
            print("🔧 [BBAccount] Kia vehicle missing vehicleKey, fetching fresh data...")
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)

            guard let matchingVehicle = fetchedVehicles.first(where: { $0.vin == bbVehicle.vin }) else {
                throw HyundaiKiaAPIError.logError("Vehicle not found in fetched data", apiName: "BBAccount")
            }

            bbVehicle.vehicleKey = matchingVehicle.vehicleKey
            print("🔧 [BBAccount] Updated vehicleKey for VIN: \(bbVehicle.vin)")
        }

        let vehicle = bbVehicle.toVehicle()
        let status: VehicleStatus
        do {
            status = try await api.fetchVehicleStatus(for: vehicle, authToken: authToken)
        } catch let error as HyundaiKiaAPIError where
            error.errorType == .invalidVehicleSession ||
            error.errorType == .invalidCredentials {
            try await handleInvalidVehicleSession(modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw HyundaiKiaAPIError.failedRetryLogin()
            }

            status = try await api.fetchVehicleStatus(for: vehicle, authToken: authToken)
        }
        LiveActivityManager.shared.updateActivity(for: bbVehicle, status: status, modelContext: modelContext)
        return status
    }

    @MainActor
    func fetchAndUpdateVehicleStatus(for vehicle: BBVehicle, modelContext: ModelContext) async throws {
        let status = try await fetchVehicleStatus(for: vehicle, modelContext: modelContext)
        vehicle.updateStatus(with: status)
    }

    @MainActor
    func updateVehicles(vehicles: [Vehicle]) {
        guard let modelContext else {
            print("🔴 [BBAccount] Model context not available for updating vehicles")
            return
        }

        // Create a map of existing BBVehicles by VIN for quick lookup
        var existingVehicleMap: [String: BBVehicle] = [:]
        var maxSortOrder = 0

        for bbVehicle in safeVehicles {
            existingVehicleMap[bbVehicle.vin] = bbVehicle
            maxSortOrder = max(maxSortOrder, bbVehicle.sortOrder)
        }

        // Track which vehicles we've processed and create new ones
        var processedVINs = Set<String>()
        var newVehiclesToAdd: [BBVehicle] = []

        // First pass: Update existing vehicles and track new ones
        for (index, vehicle) in vehicles.enumerated() {
            processedVINs.insert(vehicle.vin)

            if let existingBBVehicle = existingVehicleMap[vehicle.vin] {
                // Update existing vehicle's core data (but preserve UI state like custom names, etc.)
                existingBBVehicle.regId = vehicle.regId
                existingBBVehicle.model = vehicle.model
                existingBBVehicle.isElectric = vehicle.isElectric
                existingBBVehicle.generation = vehicle.generation
                existingBBVehicle.odometer = vehicle.odometer
                existingBBVehicle.vehicleKey = vehicle.vehicleKey
            } else {
                // Create new vehicle
                let bbVehicle = BBVehicle(from: vehicle)
                bbVehicle.sortOrder = maxSortOrder + index + 1
                modelContext.insert(bbVehicle)
                bbVehicle.account = self
                newVehiclesToAdd.append(bbVehicle)
            }
        }

        // Second pass: Remove vehicles that no longer exist
        for bbVehicle in safeVehicles.reversed() where !processedVINs.contains(bbVehicle.vin) {
            modelContext.delete(bbVehicle)
            if let vehicles = self.vehicles, let index = vehicles.firstIndex(of: bbVehicle) {
                self.vehicles?.remove(at: index)
            }
        }

        // Third pass: Add any new vehicles to the relationship
        for newVehicle in newVehiclesToAdd {
            if self.vehicles == nil {
                self.vehicles = []
            }
            self.vehicles?.append(newVehicle)
        }

        do {
            try modelContext.save()
        } catch {
            print("🔴 [BBAccount] Failed to update vehicles in SwiftData: \(error)")
        }
    }
}

// MARK: - Vehicle Commands

extension BBAccount {
    @MainActor
    func sendCommand(for bbVehicle: BBVehicle, command: VehicleCommand, modelContext: ModelContext) async throws {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await sendCommand(for: bbVehicle, command: command, modelContext: modelContext)
        }

        // For Kia vehicles, ensure vehicleKey is populated by refreshing if needed
        if brandEnum == .kia && bbVehicle.vehicleKey == nil {
            print("🔧 [BBAccount] Kia vehicle missing vehicleKey, fetching fresh data...")
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)

            guard let matchingVehicle = fetchedVehicles.first(where: { $0.vin == bbVehicle.vin }) else {
                throw HyundaiKiaAPIError.logError("Vehicle not found in fetched data", apiName: "BBAccount")
            }

            bbVehicle.vehicleKey = matchingVehicle.vehicleKey
            print("🔧 [BBAccount] Updated vehicleKey for VIN: \(bbVehicle.vin)")
        }
        
        // Start Live Activity monitoring for long-running commands
        let activityType: LiveActivityType = switch command {
        case .startClimate: .climate
        case .startCharge: .charging
        default: .none
        }
        
        if activityType != .none {
            LiveActivityManager.shared.startCommandActivity(for: bbVehicle, type: activityType, modelContext: modelContext)
        }

        let vehicle = bbVehicle.toVehicle()
        do {
            try await api.sendCommand(for: vehicle, command: command, authToken: authToken)
        } catch let error as HyundaiKiaAPIError where
            error.errorType == .invalidVehicleSession ||
            error.errorType == .invalidCredentials {
            try await handleInvalidVehicleSession(modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw HyundaiKiaAPIError.failedRetryLogin()
            }
            try await api.sendCommand(for: vehicle, command: command, authToken: authToken)
        }
    }

    @MainActor
    func lockVehicle(_ vehicle: BBVehicle, modelContext: ModelContext) async throws {
        try await sendCommand(for: vehicle, command: .lock, modelContext: modelContext)
    }

    @MainActor
    func unlockVehicle(_ vehicle: BBVehicle, modelContext: ModelContext) async throws {
        try await sendCommand(for: vehicle, command: .unlock, modelContext: modelContext)
    }

    @MainActor
    func startClimate(_ vehicle: BBVehicle, options: ClimateOptions? = nil, modelContext: ModelContext) async throws {
        let climateOptions: ClimateOptions = if let options {
            options
        } else {
            // Use vehicle's climate presets: selected preset first, then first available preset, then default
            if let selectedPreset = vehicle.safeClimatePresets.first(where: { $0.isSelected }) {
                selectedPreset.climateOptions
            } else if let firstPreset = vehicle.safeClimatePresets.first {
                firstPreset.climateOptions
            } else {
                ClimateOptions()
            }
        }

        try await sendCommand(for: vehicle, command: .startClimate(climateOptions), modelContext: modelContext)
    }

    @MainActor
    func stopClimate(_ vehicle: BBVehicle, modelContext: ModelContext) async throws {
        try await sendCommand(for: vehicle, command: .stopClimate, modelContext: modelContext)
    }

    @MainActor
    func startCharge(_ vehicle: BBVehicle, modelContext: ModelContext) async throws {
        try await sendCommand(for: vehicle, command: .startCharge, modelContext: modelContext)
    }

    @MainActor
    func stopCharge(_ vehicle: BBVehicle, modelContext: ModelContext) async throws {
        try await sendCommand(for: vehicle, command: .stopCharge, modelContext: modelContext)
    }
}

// MARK: - Static Helper Methods

extension BBAccount {
    @MainActor
    static func removeAccount(_ account: BBAccount, modelContext: ModelContext) {
        modelContext.delete(account)

        do {
            try modelContext.save()
            print("🟢 [BBAccount] Removed account from SwiftData")
        } catch {
            print("🔴 [BBAccount] Failed to remove account from SwiftData: \(error)")
        }
    }

    @MainActor
    static func updateAccount(_ account: BBAccount, password: String, pin: String, modelContext: ModelContext) {
        account.password = password
        account.pin = pin

        do {
            try modelContext.save()
            print("🟢 [BBAccount] Updated account in SwiftData")
        } catch {
            print("🔴 [BBAccount] Failed to update account in SwiftData: \(error)")
        }
    }

    @MainActor
    static func updateVehicleSortOrders(_ vehicles: [BBVehicle], modelContext: ModelContext) {
        for (index, vehicle) in vehicles.enumerated() {
            vehicle.sortOrder = index
        }

        do {
            try modelContext.save()
            print("🟢 [BBAccount] Updated vehicle sort orders")
        } catch {
            print("🔴 [BBAccount] Failed to update vehicle sort orders: \(error)")
        }
    }
}
