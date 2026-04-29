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
    var rememberMeToken: String?
    var serializedAuthToken: String?
    var deviceId: String?
    /// Timestamp of the most recent successful `fetchVehicles` call.
    /// Used by `fetchAndUpdateVehicleStatus` to decide whether the
    /// vehicle list (model name, fuelType, generation, vehicleKey,
    /// odometer) is stale enough to refetch alongside the next status
    /// request. Nil means it's never been fetched on this device.
    var lastVehiclesFetch: Date?

    @Relationship(deleteRule: .cascade) var vehicles: [BBVehicle]? = []

    var safeVehicles: [BBVehicle] {
        vehicles ?? []
    }

    @Transient
    private var api: (any APIClientProtocol)?
    @Transient
    private var cachedAuthToken: AuthToken?
    @Transient
    private var modelContextForMFA: ModelContext?
    @Transient
    private var pendingMFAError: APIError?

    /// Auth token with automatic persistence. Reads from cache first, then deserializes from storage.
    /// When set, automatically serializes to storage.
    private var authToken: AuthToken? {
        get {
            if let cached = cachedAuthToken {
                return cached
            }
            // Try to deserialize from persisted storage
            guard let serialized = serializedAuthToken,
                  let data = serialized.data(using: .utf8),
                  let token = try? JSONDecoder().decode(AuthToken.self, from: data) else {
                return nil
            }
            cachedAuthToken = token
            return token
        }
        set {
            cachedAuthToken = newValue
            if let token = newValue,
               let data = try? JSONEncoder().encode(token),
               let serialized = String(data: data, encoding: .utf8) {
                serializedAuthToken = serialized
            } else {
                serializedAuthToken = nil
            }
        }
    }

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
        try await initialize(modelContext: modelContext, deviceType: nil)
    }

    @MainActor
    func initialize(modelContext: ModelContext, deviceType: DeviceType?) async throws {
        self.modelContextForMFA = modelContext

        // If MFA is pending, throw that error instead of trying to use a stale token
        if let mfaError = pendingMFAError {
            BBLogger.info(.auth, "BBAccount: MFA is pending, re-throwing MFA error")
            throw mfaError
        }

        // If a specific device type is requested, always reinitialize the API client
        if api == nil || deviceType != nil {
            let logSink = if let deviceType {
                HTTPLogSinkManager.shared.createLogSink(for: deviceType)
            } else {
                HTTPLogSinkManager.shared.createLogSink()
            }

            // Generate a stable device ID for Kia accounts so the rmToken stays valid
            // across API client re-initializations
            if deviceId == nil {
                deviceId = UUID().uuidString.uppercased()
            }

            // Hand the API client a way to write back any rotated
            // rmToken. We can't capture `self` directly — `BBAccount`
            // is a SwiftData @Model and the closure outlives this
            // method — so the callback re-fetches the account by id
            // and persists the new value through the same context.
            let accountId = id
            let onRotate: @MainActor @Sendable (String) -> Void = { newToken in
                let descriptor = FetchDescriptor<BBAccount>(
                    predicate: #Predicate { $0.id == accountId }
                )
                guard let account = try? modelContext.fetch(descriptor).first else {
                    BBLogger.warning(
                        .auth,
                        "BBAccount: rmToken rotated but matching account not found"
                    )
                    return
                }
                guard account.rememberMeToken != newToken else { return }
                account.rememberMeToken = newToken
                do {
                    try modelContext.save()
                    BBLogger.info(.auth, "BBAccount: persisted rotated rmToken")
                } catch {
                    BBLogger.error(.auth, "BBAccount: failed to save rotated rmToken: \(error)")
                }
            }

            let configuration = APIClientFactoryConfiguration(
                region: regionEnum,
                brand: brandEnum,
                username: username,
                password: password,
                pin: pin,
                accountId: id,
                modelContext: modelContext,
                logSink: logSink,
                rememberMeToken: rememberMeToken,
                deviceId: deviceId,
                onRememberMeTokenRotated: onRotate
            )
            api = createAPIClient(configuration: configuration)
        }

        // Check if we have a valid persisted token
        if let existingToken = authToken, existingToken.isValid {
            BBLogger.info(.auth, "BBAccount: Using persisted auth token (expires: \(existingToken.expiresAt))")
            return
        }

        // Token is nil or expired, need to login
        BBLogger.info(.auth, "BBAccount: No valid token, performing login...")
        do {
            guard let api else {
                throw APIError(message: "API client not initialized")
            }
            authToken = try await api.login()
            // Clear any pending MFA error on successful login
            pendingMFAError = nil
        } catch let error as APIError where error.errorType == .requiresMFA {
            // Store MFA error so other parallel operations know MFA is required
            pendingMFAError = error
            throw error
        }
    }

    @MainActor
    func sendMFA(otpKey: String, xid: String, method: MFAMethod = .sms) async throws {
        BBLogger.info(.mfa, "BBAccount: sendMFA requested for \(username)")

        // Don't re-initialize during MFA flow - that would trigger a new login and reset the otpKey
        // The API should already be initialized from the initial login attempt that triggered MFA
        let actualApi: any APIClientProtocol = if let cached = api as? CachedAPIClient {
            cached.underlyingClient
        } else if let api {
            api
        } else {
            BBLogger.error(.api, "BBAccount: API not initialized during MFA request")
            throw APIError(message: "API not initialized. Please try logging in again.", apiName: "BBAccount")
        }

        BBLogger.info(.mfa, "BBAccount: Using API type: \(type(of: actualApi))")
        guard actualApi.supportsMFA() else {
            BBLogger.error(.api, "BBAccount: MFA not supported for this API")
            throw APIError(message: "MFA not supported for this brand", apiName: "BBAccount")
        }
        try await actualApi.sendMFACode(xid: xid, otpKey: otpKey, method: method)
    }

    @MainActor
    func verifyMFA(otpKey: String, xid: String, otp: String) async throws {
        // Don't re-initialize during MFA flow - that would trigger a new login and reset the otpKey
        // The API should already be initialized from the initial login attempt that triggered MFA
        let actualApi: any APIClientProtocol = if let cached = api as? CachedAPIClient {
            cached.underlyingClient
        } else if let api {
            api
        } else {
            throw APIError(message: "API not initialized. Please try logging in again.", apiName: "BBAccount")
        }

        guard actualApi.supportsMFA() else {
            throw APIError(message: "MFA not supported for this brand", apiName: "BBAccount")
        }

        // Step 1: Verify OTP - returns rmToken and sid
        let (newRememberMeToken, verifyOTPSid) = try await actualApi.verifyMFACode(xid: xid, otpKey: otpKey, code: otp)

        // Store the remember me token for future logins
        self.rememberMeToken = newRememberMeToken

        // Step 2: Complete login by calling authUser again with rmtoken and sid
        // Use the same API client - don't re-initialize as that would trigger another login
        let finalAuthToken = try await actualApi.completeMFALogin(sid: verifyOTPSid, rmToken: newRememberMeToken)
        self.authToken = finalAuthToken
        // Clear pending MFA error now that MFA is complete
        self.pendingMFAError = nil
        BBLogger.info(.api, "BBAccount: MFA complete - final session: \(finalAuthToken.accessToken.prefix(20))...")
    }

    /// Determines if an error should trigger a full re-authentication.
    ///
    /// Only errors that genuinely indicate the session is no longer
    /// valid should clear the auth token and trigger a fresh `login()`
    /// (which on Kia means another `authUser` call, and after enough
    /// of those Kia's anti-fraud logic challenges the rmToken and
    /// forces MFA again). Transient failures — server errors,
    /// concurrent-request rejections, network blips — are surfaced to
    /// the caller without touching the session.
    private func shouldReauthenticate(for error: APIError) -> Bool {
        switch error.errorType {
        case .invalidCredentials,
             .invalidVehicleSession,
             .failedRetryLogin,
             .kiaInvalidRequest:
            return true
        case .requiresMFA,
             .invalidPin,
             .serverError,
             .concurrentRequest,
             .regionNotSupported,
             .general:
            return false
        }
    }

    @MainActor
    private func handleAPIError(_ error: APIError, modelContext: ModelContext) async throws {
        BBLogger.info(.api, "BBAccount: API error (\(error.errorType)) detected, performing full re-initialization...")

        clearAPICache()
        self.api = nil
        self.authToken = nil
        try await initialize(modelContext: modelContext)

        guard let api, let authToken else {
            throw APIError.failedRetryLogin()
        }
        let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)
        updateVehicles(vehicles: fetchedVehicles)

        BBLogger.info(.api, "BBAccount: Re-initialization complete")
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
        } catch let error as APIError where shouldReauthenticate(for: error) {
            try await handleAPIError(error, modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw APIError.failedRetryLogin()
            }
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)
            updateVehicles(vehicles: fetchedVehicles)
        }
    }

    /// Fetches a vehicle's status.
    /// - Parameter cached: pass `false` when the user explicitly asked for
    ///   fresh data (manual sync, post-command verification). Defaults to
    ///   `true` for background/widget reads so we don't repeatedly wake the
    ///   vehicle modem.
    @MainActor
    func fetchVehicleStatus(
        for bbVehicle: BBVehicle,
        modelContext: ModelContext,
        cached: Bool = true
    ) async throws -> VehicleStatus {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await fetchVehicleStatus(for: bbVehicle, modelContext: modelContext, cached: cached)
        }

        // For Kia vehicles, ensure vehicleKey is populated by refreshing if needed
        if brandEnum == .kia && bbVehicle.vehicleKey == nil {
            BBLogger.debug(.api, "BBAccount: Kia vehicle missing vehicleKey, fetching fresh data...")
            try await loadVehicles(modelContext: modelContext)
            return try await fetchVehicleStatus(for: bbVehicle, modelContext: modelContext, cached: cached)
        }

        let vehicle = bbVehicle.toVehicle()
        let status: VehicleStatus
        do {
            status = try await api.fetchVehicleStatus(for: vehicle, authToken: authToken, cached: cached)
        } catch let error as APIError where shouldReauthenticate(for: error) {
            try await handleAPIError(error, modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw APIError.failedRetryLogin()
            }

            status = try await api.fetchVehicleStatus(for: vehicle, authToken: authToken, cached: cached)
        }
        LiveActivityManager.shared.updateActivity(for: bbVehicle, status: status, modelContext: modelContext)
        return status
    }

    /// Maximum age of the cached vehicle list before
    /// `fetchAndUpdateVehicleStatus` will re-fetch vehicles alongside
    /// the requested status. Two hours covers the day-to-day staleness
    /// (model name, fuelType, generation, vehicleKey, odometer) without
    /// adding meaningful traffic — vehicle metadata barely changes.
    static let vehicleListMaxAge: TimeInterval = 2 * 3600

    @MainActor
    func fetchAndUpdateVehicleStatus(
        for vehicle: BBVehicle,
        modelContext: ModelContext,
        cached: Bool = true,
        forceVehicleListRefresh: Bool = false
    ) async throws {
        // Decide whether to also refresh the vehicle list. Manual user
        // refreshes always do (`forceVehicleListRefresh: true`). Background
        // / widget reads only do when the list is older than the threshold.
        let isStale: Bool = {
            guard let last = lastVehiclesFetch else { return true }
            return Date().timeIntervalSince(last) > Self.vehicleListMaxAge
        }()

        if forceVehicleListRefresh || isStale {
            do {
                BBLogger.info(
                    .api,
                    "BBAccount: refreshing vehicle list before status (force=\(forceVehicleListRefresh), stale=\(isStale))"
                )
                try await loadVehicles(modelContext: modelContext)
            } catch {
                if forceVehicleListRefresh {
                    // The user explicitly asked for fresh data — don't
                    // silently skip past a list-fetch failure.
                    throw error
                } else {
                    // Best-effort on automatic paths: log and proceed
                    // with a stale list so the user still gets a status
                    // update from the periodic poll.
                    BBLogger.warning(
                        .api,
                        "BBAccount: vehicle list refresh failed during background poll, falling back to cached list: \(error)"
                    )
                }
            }
        }

        let status = try await fetchVehicleStatus(for: vehicle, modelContext: modelContext, cached: cached)
        vehicle.updateStatus(with: status)
    }

    @MainActor
    func updateVehicles(vehicles: [Vehicle]) {
        guard let modelContext else {
            BBLogger.error(.api, "BBAccount: Model context not available for updating vehicles")
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
                existingBBVehicle.fuelType = vehicle.fuelType
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

        // Mark the list as fresh — drives the staleness check in
        // `fetchAndUpdateVehicleStatus(forceVehicleListRefresh:)`.
        lastVehiclesFetch = Date()

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.api, "BBAccount: Failed to update vehicles in SwiftData: \(error)")
        }
    }
}

// MARK: - Vehicle Commands

extension BBAccount {
    @MainActor
    func sendCommand(
        for bbVehicle: BBVehicle,
        command: VehicleCommand,
        modelContext: ModelContext,
        climatePresetName: String? = nil,
        climatePresetIcon: String? = nil
    ) async throws {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await sendCommand(
                for: bbVehicle,
                command: command,
                modelContext: modelContext,
                climatePresetName: climatePresetName,
                climatePresetIcon: climatePresetIcon
            )
        }

        // For Kia vehicles, ensure vehicleKey is populated by refreshing if needed
        if brandEnum == .kia && bbVehicle.vehicleKey == nil {
            BBLogger.debug(.api, "BBAccount: Kia vehicle missing vehicleKey, fetching fresh data...")
            let fetchedVehicles = try await api.fetchVehicles(authToken: authToken)

            guard let matchingVehicle = fetchedVehicles.first(where: { $0.vin == bbVehicle.vin }) else {
                throw APIError.logError("Vehicle not found in fetched data", apiName: "BBAccount")
            }

            bbVehicle.vehicleKey = matchingVehicle.vehicleKey
            BBLogger.debug(.api, "BBAccount: Updated vehicleKey for VIN: \(bbVehicle.vin)")
        }

        // Start Live Activity monitoring for long-running commands
        let activityType: LiveActivityType = switch command {
        case .startClimate: .climate
        case .startCharge: .charging
        default: .none
        }

        if activityType != .none {
            LiveActivityManager.shared.startCommandActivity(
                for: bbVehicle,
                type: activityType,
                modelContext: modelContext,
                climatePresetName: climatePresetName,
                climatePresetIcon: climatePresetIcon
            )
        }

        let vehicle = bbVehicle.toVehicle()
        do {
            try await api.sendCommand(for: vehicle, command: command, authToken: authToken)
        } catch let error as APIError where shouldReauthenticate(for: error) {
            try await handleAPIError(error, modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw APIError.failedRetryLogin()
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
    func startClimate(
        _ vehicle: BBVehicle,
        options: ClimateOptions? = nil,
        modelContext: ModelContext,
        presetName: String? = nil,
        presetIcon: String? = nil
    ) async throws {
        var resolvedPresetName = presetName
        var resolvedPresetIcon = presetIcon
        let climateOptions: ClimateOptions

        if let options {
            climateOptions = options
        } else {
            // Use vehicle's climate presets: selected preset first, then first available preset, then default
            if let selectedPreset = vehicle.safeClimatePresets.first(where: { $0.isSelected }) {
                climateOptions = selectedPreset.climateOptions
                resolvedPresetName = resolvedPresetName ?? selectedPreset.name
                resolvedPresetIcon = resolvedPresetIcon ?? selectedPreset.iconName
            } else if let firstPreset = vehicle.safeClimatePresets.first {
                climateOptions = firstPreset.climateOptions
                resolvedPresetName = resolvedPresetName ?? firstPreset.name
                resolvedPresetIcon = resolvedPresetIcon ?? firstPreset.iconName
            } else {
                climateOptions = ClimateOptions()
            }
        }

        try await sendCommand(
            for: vehicle,
            command: .startClimate(climateOptions),
            modelContext: modelContext,
            climatePresetName: resolvedPresetName,
            climatePresetIcon: resolvedPresetIcon
        )
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

    @MainActor
    func setTargetSOC(_ vehicle: BBVehicle, acLevel: Int, dcLevel: Int, modelContext: ModelContext) async throws {
        try await sendCommand(
            for: vehicle,
            command: .setTargetSOC(acLevel: acLevel, dcLevel: dcLevel),
            modelContext: modelContext
        )
    }
}

// MARK: - EV Trip Details

extension BBAccount {
    /// Fetches EV trip details for a vehicle. Returns nil if the API doesn't support this feature.
    @MainActor
    func fetchEVTripDetails(for bbVehicle: BBVehicle, modelContext: ModelContext) async throws -> [EVTripDetail]? {
        guard let api, let authToken else {
            try await initialize(modelContext: modelContext)
            return try await fetchEVTripDetails(for: bbVehicle, modelContext: modelContext)
        }

        let vehicle = bbVehicle.toVehicle()

        do {
            return try await api.fetchEVTripDetails(for: vehicle, authToken: authToken)
        } catch let error as APIError where shouldReauthenticate(for: error) {
            try await handleAPIError(error, modelContext: modelContext)
            guard let api = self.api, let authToken = self.authToken else {
                throw APIError.failedRetryLogin()
            }
            return try await api.fetchEVTripDetails(for: vehicle, authToken: authToken)
        }
    }

    /// Returns true if the account's API supports EV trip details
    var supportsEVTripDetails: Bool {
        // Currently only Hyundai USA supports trip details
        brandEnum == .hyundai && regionEnum == .usa
    }
}

// MARK: - Static Helper Methods

extension BBAccount {
    @MainActor
    static func removeAccount(_ account: BBAccount, modelContext: ModelContext) {
        modelContext.delete(account)

        do {
            try modelContext.save()
            BBLogger.info(.api, "BBAccount: Removed account from SwiftData")
        } catch {
            BBLogger.error(.api, "BBAccount: Failed to remove account from SwiftData: \(error)")
        }
    }

    @MainActor
    static func updateAccount(_ account: BBAccount, password: String, pin: String, modelContext: ModelContext) {
        account.password = password
        account.pin = pin

        do {
            try modelContext.save()
            BBLogger.info(.api, "BBAccount: Updated account in SwiftData")
        } catch {
            BBLogger.error(.api, "BBAccount: Failed to update account in SwiftData: \(error)")
        }
    }

    @MainActor
    static func updateVehicleSortOrders(_ vehicles: [BBVehicle], modelContext: ModelContext) {
        for (index, vehicle) in vehicles.enumerated() {
            vehicle.sortOrder = index
        }

        do {
            try modelContext.save()
            BBLogger.info(.api, "BBAccount: Updated vehicle sort orders")
        } catch {
            BBLogger.error(.api, "BBAccount: Failed to update vehicle sort orders: \(error)")
        }
    }
}

// MARK: - Codable Conformance for Export

extension BBAccount: Encodable {
    enum CodingKeys: String, CodingKey {
        case id, username, password, pin, brand, region, dateCreated
        case rememberMeToken, serializedAuthToken, vehicles
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(pin, forKey: .pin)
        try container.encode(brand, forKey: .brand)
        try container.encode(region, forKey: .region)
        try container.encode(dateCreated, forKey: .dateCreated)
        try container.encodeIfPresent(rememberMeToken, forKey: .rememberMeToken)
        try container.encodeIfPresent(serializedAuthToken, forKey: .serializedAuthToken)
        try container.encode(safeVehicles, forKey: .vehicles)
    }
}
