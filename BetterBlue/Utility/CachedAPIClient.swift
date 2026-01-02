//
//  CachedAPIClient.swift
//  BetterBlue
//
//  A caching and request deduplication layer for API clients
//

import BetterBlueKit
import Foundation

@MainActor
class CachedAPIClient: APIClientProtocol {
    let underlyingClient: any APIClientProtocol

    // Cache for storing responses with timestamps
    private var cache: [CacheKey: CacheEntry] = [:]

    // Track ongoing requests to prevent duplicates - using a protocol-based approach
    private var ongoingRequests: [RequestKey: any OngoingRequest] = [:]

    // Cache TTL in seconds
    private let cacheTTL: TimeInterval = 5.0

    init(underlyingClient: any APIClientProtocol) {
        self.underlyingClient = underlyingClient
    }

    // MARK: - APIClientProtocol Implementation

    func login() async throws -> AuthToken {
        let requestKey = RequestKey.login
        let cacheKey = CacheKey.login

        // Check if we have a cached response that's still valid
        if let cachedEntry = cache[cacheKey],
           Date().timeIntervalSince(cachedEntry.timestamp) < cacheTTL,
           let cachedToken = cachedEntry.response as? AuthToken {
            print("🟢 [CachedAPIClient] Using cached login response")
            return cachedToken
        }

        // Check if there's already an ongoing request of this type
        if let ongoingRequest = ongoingRequests[requestKey] {
            print("🟡 [CachedAPIClient] Waiting for ongoing login request")
            guard let token = try await ongoingRequest.waitForCompletion() as? AuthToken else {
                throw APIError.logError("Error retrieving login token from ongoing request")
            }
            return token
        }

        // Create new request task
        let task = Task<AuthToken, any Error> {
            defer {
                ongoingRequests.removeValue(forKey: requestKey)
            }

            print("🔵 [CachedAPIClient] Performing new login request")
            let result = try await underlyingClient.login()

            // Cache successful response
            cache[cacheKey] = CacheEntry(response: result, timestamp: Date())

            return result
        }

        ongoingRequests[requestKey] = TypedOngoingRequest(task: task)
        return try await task.value
    }

    func fetchVehicles(authToken: AuthToken) async throws -> [Vehicle] {
        let requestKey = RequestKey.fetchVehicles
        let cacheKey = CacheKey.fetchVehicles

        // Check if we have a cached response that's still valid
        if let cachedEntry = cache[cacheKey],
           Date().timeIntervalSince(cachedEntry.timestamp) < cacheTTL,
           let cachedVehicles = cachedEntry.response as? [Vehicle] {
            print("🟢 [CachedAPIClient] Using cached fetchVehicles response")
            return cachedVehicles
        }

        // Check if there's already an ongoing request of this type
        if let ongoingRequest = ongoingRequests[requestKey] {
            print("🟡 [CachedAPIClient] Waiting for ongoing fetchVehicles request")
            guard let vehicles = try await ongoingRequest.waitForCompletion() as? [Vehicle] else {
                throw APIError.logError("Error retrieving vehicles from ongoing request")
            }
            return vehicles
        }

        // Create new request task
        let task = Task<[Vehicle], any Error> {
            defer {
                ongoingRequests.removeValue(forKey: requestKey)
            }

            print("🔵 [CachedAPIClient] Performing new fetchVehicles request")
            let result = try await underlyingClient.fetchVehicles(authToken: authToken)

            // Cache successful response
            cache[cacheKey] = CacheEntry(response: result, timestamp: Date())

            return result
        }

        ongoingRequests[requestKey] = TypedOngoingRequest(task: task)
        return try await task.value
    }

    func fetchVehicleStatus(for vehicle: Vehicle, authToken: AuthToken) async throws -> VehicleStatus {
        let requestKey = RequestKey.fetchVehicleStatus(vin: vehicle.vin)
        let cacheKey = CacheKey.fetchVehicleStatus(vin: vehicle.vin)

        // Check if we have a cached response that's still valid
        if let cachedEntry = cache[cacheKey],
           Date().timeIntervalSince(cachedEntry.timestamp) < cacheTTL,
           let cachedStatus = cachedEntry.response as? VehicleStatus {
            print("🟢 [CachedAPIClient] Using cached fetchVehicleStatus response for VIN: \(vehicle.vin)")
            return cachedStatus
        }

        // Check if there's already an ongoing request of this type
        if let ongoingRequest = ongoingRequests[requestKey] {
            print("🟡 [CachedAPIClient] Waiting for ongoing fetchVehicleStatus request for VIN: \(vehicle.vin)")
            guard let vehicleStatus = try await ongoingRequest.waitForCompletion() as? VehicleStatus else {
                throw APIError.logError("Error retrieving vehicles from ongoing request")
            }
            return vehicleStatus
        }

        // Create new request task
        let task = Task<VehicleStatus, any Error> {
            defer {
                ongoingRequests.removeValue(forKey: requestKey)
            }

            print("🔵 [CachedAPIClient] Performing new fetchVehicleStatus request for VIN: \(vehicle.vin)")
            let result = try await underlyingClient.fetchVehicleStatus(for: vehicle, authToken: authToken)

            // Cache successful response
            cache[cacheKey] = CacheEntry(response: result, timestamp: Date())

            return result
        }

        ongoingRequests[requestKey] = TypedOngoingRequest(task: task)
        return try await task.value
    }

    func sendCommand(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken) async throws {
        // Commands should not be cached or deduplicated as they perform actions
        // However, we still want to prevent multiple identical commands from running simultaneously
        let requestKey = RequestKey.sendCommand(vin: vehicle.vin, command: String(describing: command))

        // Check if there's already an ongoing command of this type for this vehicle
        if let ongoingRequest = ongoingRequests[requestKey] {
            print("🟡 [CachedAPIClient] Waiting for ongoing sendCommand request for VIN: \(vehicle.vin)")
            _ = try await ongoingRequest.waitForCompletion()
            return
        }

        // Create new request task
        let task = Task<Void, any Error> {
            defer {
                ongoingRequests.removeValue(forKey: requestKey)
            }

            print("🔵 [CachedAPIClient] Performing new sendCommand request for VIN: \(vehicle.vin)")
            try await underlyingClient.sendCommand(for: vehicle, command: command, authToken: authToken)
        }

        ongoingRequests[requestKey] = TypedOngoingRequest(task: task)
        try await task.value
    }

    // MARK: - Cache Management

    func clearCache() {
        cache.removeAll()
        print("🧹 [CachedAPIClient] Cache cleared")
    }

    func clearExpiredCache() {
        let now = Date()
        let expiredKeys = cache.compactMap { key, entry in
            now.timeIntervalSince(entry.timestamp) >= cacheTTL ? key : nil
        }

        for key in expiredKeys {
            cache.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            print("🧹 [CachedAPIClient] Cleared \(expiredKeys.count) expired cache entries")
        }
    }

    // Expose cache statistics for debugging
    var cacheStatistics: CacheStatistics {
        let now = Date()
        let validEntries = cache.values.filter { now.timeIntervalSince($0.timestamp) < cacheTTL }
        let expiredEntries = cache.values.filter { now.timeIntervalSince($0.timestamp) >= cacheTTL }

        return CacheStatistics(
            totalEntries: cache.count,
            validEntries: validEntries.count,
            expiredEntries: expiredEntries.count,
            ongoingRequests: ongoingRequests.count,
        )
    }
}

// MARK: - Supporting Types

private protocol OngoingRequest {
    func waitForCompletion() async throws -> Any
}

private struct TypedOngoingRequest<T: Sendable>: OngoingRequest {
    let task: Task<T, any Error>

    func waitForCompletion() async throws -> Any {
        try await task.value
    }
}

private struct CacheEntry {
    let response: Any
    let timestamp: Date
}

private enum CacheKey: Hashable {
    case login
    case fetchVehicles
    case fetchVehicleStatus(vin: String)
}

private enum RequestKey: Hashable {
    case login
    case fetchVehicles
    case fetchVehicleStatus(vin: String)
    case sendCommand(vin: String, command: String)
}

struct CacheStatistics {
    let totalEntries: Int
    let validEntries: Int
    let expiredEntries: Int
    let ongoingRequests: Int

    var description: String {
        "Cache: \(validEntries) valid, \(expiredEntries) expired, \(ongoingRequests) ongoing"
    }
}
