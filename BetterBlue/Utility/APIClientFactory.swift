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

    switch effectiveBrand {
    case .hyundai:
        print("🏗️ [APIClientFactory] Creating Hyundai API client")
        let endpointProvider = HyundaiAPIEndpointProvider(configuration: configuration.apiConfiguration)
        let underlyingClient = HyundaiAPIClient(
            configuration: configuration.apiConfiguration,
            endpointProvider: endpointProvider,
        )
        return CachedAPIClient(underlyingClient: underlyingClient)
    case .kia:
        print("🏗️ [APIClientFactory] Creating Kia API client")
        let endpointProvider = KiaAPIEndpointProvider(configuration: configuration.apiConfiguration)
        let underlyingClient = KiaAPIClient(
            configuration: configuration.apiConfiguration,
            endpointProvider: endpointProvider,
        )
        return CachedAPIClient(underlyingClient: underlyingClient)
    case .fake:
        print("🏗️ [APIClientFactory] Creating SwiftData-based Fake API client")
        let vehicleProvider = SwiftDataFakeVehicleProvider(modelContext: configuration.modelContext)
        let underlyingClient = FakeAPIClient(
            configuration: configuration.apiConfiguration,
            vehicleProvider: vehicleProvider,
        )
        return CachedAPIClient(underlyingClient: underlyingClient)
    }
}
