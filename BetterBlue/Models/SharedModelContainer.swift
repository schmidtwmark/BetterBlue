//
//  SharedModelContainer.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/4/25.
//

import BetterBlueKit
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
    let appGroupID = AppIdentifiers.appGroup
    if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
        return appGroupURL.appendingPathComponent("BetterBlue.sqlite")
    } else {
        BBLogger.warning(.app, "BetterBlue: App Group container not accessible from current context")
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

func createContainer(storeURL: URL, schema: Schema, cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .automatic) throws -> ModelContainer {
    do {
        let modelConfiguration = ModelConfiguration(url: storeURL, cloudKitDatabase: cloudKitDatabase)
        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    } catch {
        BBLogger.error(.app, "BetterBlue: Failed to create ModelContainer: \(error)")
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

/// Removes orphaned climate presets that have no vehicle relationship.
/// These are leftover from before the relationship was properly set during creation.
@MainActor
func cleanupOrphanedClimatePresets(container: ModelContainer) {
    let context = container.mainContext

    do {
        let presetDescriptor = FetchDescriptor<ClimatePreset>()
        let allPresets = try context.fetch(presetDescriptor)

        var deletedCount = 0
        for preset in allPresets where preset.vehicle == nil {
            context.delete(preset)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try context.save()
            BBLogger.info(.app, "Cleaned up \(deletedCount) orphaned climate preset(s)")
        }
    } catch {
        BBLogger.error(.app, "Failed to cleanup orphaned climate presets: \(error)")
    }
}

/// Removes "zombie" vehicles whose parent `BBAccount` no longer exists.
/// Normally `BBAccount` → `BBVehicle` is cascade-delete, but interrupted
/// CloudKit syncs and earlier schema iterations can leave orphan vehicle
/// rows that Siri/App Intents/widget pickers would otherwise still list.
/// Their cascaded `climatePresets` are dropped by SwiftData automatically
/// once the vehicle goes away.
@MainActor
func cleanupOrphanedVehicles(container: ModelContainer) {
    let context = container.mainContext

    do {
        let vehicleDescriptor = FetchDescriptor<BBVehicle>()
        let allVehicles = try context.fetch(vehicleDescriptor)

        var deletedCount = 0
        for vehicle in allVehicles where vehicle.account == nil {
            BBLogger.info(.app, "Purging orphaned vehicle \(vehicle.vin) (\(vehicle.displayName))")
            context.delete(vehicle)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try context.save()
            BBLogger.info(.app, "Cleaned up \(deletedCount) orphaned vehicle(s)")
        }
    } catch {
        BBLogger.error(.app, "Failed to cleanup orphaned vehicles: \(error)")
    }
}

/// Removes duplicate `BBVehicle` rows that share a VIN within one account.
/// `BBAccount.updateVehicles()` keys existing vehicles by VIN, so it never
/// creates a second row itself — but an iCloud merge (reinstall, second
/// device) can land one, and once two exist neither is ever swept up
/// because both match the fetched VIN. The duplicate is worse than
/// cosmetic: intents and widgets resolve vehicles by VIN and can land on
/// the wrong copy, running commands with that copy's presets. Keep the
/// visible row (then lowest sort order) and delete the rest; their
/// cascaded presets go with them.
@MainActor
func cleanupDuplicateVehicles(container: ModelContainer) {
    let context = container.mainContext

    do {
        let allVehicles = try context.fetch(FetchDescriptor<BBVehicle>())

        var groups: [String: [BBVehicle]] = [:]
        for vehicle in allVehicles {
            guard let account = vehicle.account else { continue }
            groups["\(account.id)|\(vehicle.vin)", default: []].append(vehicle)
        }

        var deletedCount = 0
        for (_, rows) in groups where rows.count > 1 {
            let ordered = rows.sorted {
                ($0.isHidden ? 1 : 0, $0.sortOrder) < ($1.isHidden ? 1 : 0, $1.sortOrder)
            }
            let keeper = ordered[0]
            for duplicate in ordered.dropFirst() {
                BBLogger.info(
                    .app,
                    "Purging duplicate vehicle \(duplicate.vin.suffix(6)) (\(duplicate.displayName)), keeping \(keeper.displayName)"
                )
                context.delete(duplicate)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            try context.save()
            BBLogger.info(.app, "Cleaned up \(deletedCount) duplicate vehicle(s)")
        }
    } catch {
        BBLogger.error(.app, "Failed to cleanup duplicate vehicles: \(error)")
    }
}

/// Creates a shared ModelContainer for use across main app, widget, and watch app.
/// - Parameter enableCloudKit: Whether to enable CloudKit sync. Set to `false` for
///   App Intents and widgets running in the background to avoid `0xdead10cc` crashes
///   caused by holding SQLite file locks during process suspension.
func createSharedModelContainer(enableCloudKit: Bool = true) throws -> ModelContainer {
    let schema = Schema([
        BBAccount.self,
        BBVehicle.self,
        BBHTTPLog.self,
        ClimatePreset.self
    ], version: .init(1, 0, 9))

    let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = enableCloudKit ? .automatic : .none

    #if targetEnvironment(simulator)
        let storeURL = getSimulatorStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema, cloudKitDatabase: cloudKitDatabase)
    #else
        let cloudConfig = ModelConfiguration(
            AppIdentifiers.iCloudContainer,
            cloudKitDatabase: cloudKitDatabase
        )

        if let container = try? ModelContainer(
            for: schema,
            configurations: [cloudConfig]
        ) {
            return container
        }
        let storeURL = try getAppGroupStoreURL()
        return try createContainer(storeURL: storeURL, schema: schema, cloudKitDatabase: cloudKitDatabase)
    #endif
}
