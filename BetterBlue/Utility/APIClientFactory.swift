//
//  APIClientFactory.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/21/25.
//

import BetterBlueKit
import Foundation
import SwiftData

struct APIClientFactoryConfiguration {
    let apiConfiguration: APIClientConfiguration
    let modelContext: ModelContext
    init(
        region: Region,
        brand: Brand,
        username: String,
        password: String,
        pin: String,
        accountId: UUID,
        modelContext: ModelContext,
        logSink: HTTPLogSink? = nil,
        rememberMeToken: String? = nil
    ) {
        apiConfiguration = APIClientConfiguration(
            region: region,
            brand: brand,
            username: username,
            password: password,
            pin: pin,
            accountId: accountId,
            logSink: logSink,
            rememberMeToken: rememberMeToken
        )
        self.modelContext = modelContext
    }
}

@MainActor
func createAPIClient(configuration: APIClientFactoryConfiguration) -> any APIClientProtocol {
    // Override brand selection for test account - always use fake client with app group storage
    let effectiveBrand = isTestAccount(
        username: configuration.apiConfiguration.username,
        password: configuration.apiConfiguration.password,
    ) ? .fake : configuration.apiConfiguration.brand

    // Handle fake brand separately (app-specific, not in BetterBlueKit)
    if effectiveBrand == .fake {
        BBLogger.info(.api, "APIClientFactory: Creating SwiftData-based Fake API client")
        let vehicleProvider = SwiftDataFakeVehicleProvider(modelContext: configuration.modelContext)
        let underlyingClient = FakeAPIClient(
            configuration: configuration.apiConfiguration,
            vehicleProvider: vehicleProvider,
        )
        return CachedAPIClient(underlyingClient: underlyingClient)
    }

    // Use BetterBlueKit factory for real API clients
    BBLogger.info(.api, "APIClientFactory: Creating \(effectiveBrand.displayName) API client for \(configuration.apiConfiguration.region.rawValue)")

    // Create a configuration with the effective brand
    let effectiveConfiguration = APIClientConfiguration(
        region: configuration.apiConfiguration.region,
        brand: effectiveBrand,
        username: configuration.apiConfiguration.username,
        password: configuration.apiConfiguration.password,
        pin: configuration.apiConfiguration.pin,
        accountId: configuration.apiConfiguration.accountId,
        logSink: configuration.apiConfiguration.logSink,
        rememberMeToken: configuration.apiConfiguration.rememberMeToken
    )

    do {
        let underlyingClient = try createBetterBlueKitAPIClient(configuration: effectiveConfiguration)
        return CachedAPIClient(underlyingClient: underlyingClient)
    } catch {
        // This shouldn't happen in normal usage since we check the brand above,
        // but if it does, fall back to a sensible error state
        BBLogger.error(.api, "APIClientFactory: Failed to create client: \(error.localizedDescription)")
        // Return a fake client as fallback to prevent crashes
        let vehicleProvider = SwiftDataFakeVehicleProvider(modelContext: configuration.modelContext)
        let underlyingClient = FakeAPIClient(
            configuration: configuration.apiConfiguration,
            vehicleProvider: vehicleProvider,
        )
        return CachedAPIClient(underlyingClient: underlyingClient)
    }
}
