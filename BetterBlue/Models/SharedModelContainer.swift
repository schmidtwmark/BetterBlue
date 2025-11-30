//
//  SharedModelContainer.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/4/25.
//

import Foundation
import SwiftData

func getSimulatorStoreURL() -> URL {
    // In simulator, use a fixed shared location to work around App Group container isolation
    let sharedSimulatorPath = "/tmp/BetterBlue_Shared"
    try? FileManager.default.createDirectory(
        atPath: sharedSimulatorPath,
        withIntermediateDirectories: true,
        attributes: nil,
    )
    return URL(fileURLWithPath: sharedSimulatorPath).appendingPathComponent("BetterBlue.sqlite")
}

func getAppGroupStoreURL() throws -> URL {
    let appGroupID = "group.com.betterblue.shared"
    if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
        return appGroupURL.appendingPathComponent("BetterBlue.sqlite")
    } else {
        print("⚠️ [BetterBlue] App Group container not accessible from current context")
        throw NSError(
            domain: "BetterBlue",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Vehicle data not accessible. Please open the BetterBlue app first to sync your vehicles.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Open the BetterBlue app and try again."
            ],
        )
    }
}

func createContainer(storeURL: URL, schema: Schema) throws -> ModelContainer {
    do {
        let modelConfiguration = ModelConfiguration(url: storeURL, cloudKitDatabase: .automatic)
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
        print("❌ [BetterBlue] Failed to create ModelContainer: \(error)")
        throw NSError(
            domain: "BetterBlue",
            code: 1002,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to create data storage",
                NSLocalizedRecoverySuggestionErrorKey:
                    "Try restarting the app. If the problem persists, contact support."
            ],
        )
    }
}

/// Creates a shared ModelContainer for use across main app, widget, and watch app
func createSharedModelContainer() throws -> ModelContainer {
    let schema = Schema([
        BBAccount.self,
        BBVehicle.self,
        BBHTTPLog.self,
        ClimatePreset.self
    ], version: .init(1, 0, 8))

    #if targetEnvironment(simulator)
        let storeURL = getSimulatorStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema)
    #else
        let cloudConfig = ModelConfiguration(
            "iCloud.com.markschmidt.BetterBlue",
            cloudKitDatabase: .automatic
        )

        if let container = try? ModelContainer(
            for: schema,
            configurations: [cloudConfig]
        ) {
            return container
        }
        let storeURL = try getAppGroupStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema)
    #endif
}
