//
//  VehicleTimelineProvider.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleWidgetEntry: TimelineEntry {
    let date: Date
    let vehicle: VehicleEntity?
    let configuration: VehicleWidgetIntent
}

struct VehicleTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: Date(), vehicle: nil, configuration: VehicleWidgetIntent())
    }

    func snapshot(for configuration: VehicleWidgetIntent, in _: Context) async -> VehicleWidgetEntry {
        if let vehicle = configuration.vehicle {
            return VehicleWidgetEntry(date: Date(), vehicle: vehicle, configuration: configuration)
        }

        // Try to get the first available vehicle
        do {
            let vehicles = try await VehicleQuery().suggestedEntities()
            let firstVehicle = vehicles.first
            return VehicleWidgetEntry(date: Date(), vehicle: firstVehicle, configuration: configuration)
        } catch {
            return VehicleWidgetEntry(date: Date(), vehicle: nil, configuration: configuration)
        }
    }

    func timeline(for configuration: VehicleWidgetIntent, in _: Context) async -> Timeline<VehicleWidgetEntry> {
        let currentDate = Date()
        let refreshInterval = await MainActor.run {
            AppSettings.shared.widgetRefreshInterval.timeInterval
        }

        // Try to refresh vehicle data
        let updatedVehicle = await refreshVehicleData(for: configuration)

        // Create timeline entries
        var entries: [VehicleWidgetEntry] = []

        // Add current entry
        entries.append(VehicleWidgetEntry(
            date: currentDate,
            vehicle: updatedVehicle,
            configuration: configuration
        ))

        // Add next refresh entry
        let nextRefreshDate = currentDate.addingTimeInterval(refreshInterval)
        entries.append(VehicleWidgetEntry(
            date: nextRefreshDate,
            vehicle: updatedVehicle,
            configuration: configuration
        ))

        return Timeline(entries: entries, policy: .atEnd)
    }

    private func refreshVehicleData(for configuration: VehicleWidgetIntent) async -> VehicleEntity? {
        do {
            let modelContainer = try createSharedModelContainer()

            // Configure the HTTP log sink manager for widget
            await MainActor.run {
                HTTPLogSinkManager.shared.configure(with: modelContainer, deviceType: .widget)
            }

            let context = ModelContext(modelContainer)

            // Get the target vehicle
            let targetVehicle: BBVehicle?
            if let configVehicle = configuration.vehicle {
                let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
                targetVehicle = vehicles.first { $0.vin == configVehicle.vin }
            } else {
                let descriptor = FetchDescriptor<BBVehicle>(
                    predicate: #Predicate { !$0.isHidden },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
                let vehicles = try context.fetch(descriptor)
                targetVehicle = vehicles.first
            }

            guard let bbVehicle = targetVehicle,
                  let account = bbVehicle.account
            else {
                print("🔄 [Widget] No vehicle or account found for refresh")
                return await getVehicleEntityFromContext(for: configuration, context: context)
            }

            let vehicleName = bbVehicle.displayName
            let lastUpdated = bbVehicle.lastUpdated ?? Date.distantPast
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdated)
            let thirtyMinutesInSeconds: TimeInterval = 30 * 60

            if timeSinceLastUpdate < thirtyMinutesInSeconds {
                print("📱 [Widget] Using fresh data for \(vehicleName) (updated \(Int(timeSinceLastUpdate / 60))m ago)")
            } else {
                print("🔄 [Widget] Refreshing stale vehicle status for \(vehicleName) (last updated \(Int(timeSinceLastUpdate / 60))m ago)")

                // Refresh vehicle status only if data is stale
                try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)

                print("✅ [Widget] Successfully refreshed \(vehicleName)")
            }

            // Create vehicle entity on the main actor to avoid capture issues
            let unit = await MainActor.run { AppSettings.shared.preferredDistanceUnit }
            let vehicleEntity = VehicleEntity(from: bbVehicle, with: unit)
            return vehicleEntity

        } catch {
            print("❌ [Widget] Failed to refresh vehicle data: \(error)")

            // Fall back to cached data
            do {
                let modelContainer = try createSharedModelContainer()

                // Configure the HTTP log sink manager for widget fallback
                await MainActor.run {
                    HTTPLogSinkManager.shared.configure(with: modelContainer, deviceType: .widget)
                }

                let context = ModelContext(modelContainer)
                return await getVehicleEntityFromContext(for: configuration, context: context)
            } catch {
                print("❌ [Widget] Failed to get cached vehicle data: \(error)")
                return nil
            }
        }
    }

    private func getVehicleEntityFromContext(
        for configuration: VehicleWidgetIntent,
        context: ModelContext
    ) async -> VehicleEntity? {
        do {
            let targetVehicle: BBVehicle?
            if let configVehicle = configuration.vehicle {
                let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
                targetVehicle = vehicles.first { $0.vin == configVehicle.vin }
            } else {
                let descriptor = FetchDescriptor<BBVehicle>(
                    predicate: #Predicate { !$0.isHidden },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
                let vehicles = try context.fetch(descriptor)
                targetVehicle = vehicles.first
            }

            guard let bbVehicle = targetVehicle else {
                return nil
            }

            let unit = await MainActor.run { AppSettings.shared.preferredDistanceUnit }
            let vehicleEntity = VehicleEntity(from: bbVehicle, with: unit)
            return vehicleEntity

        } catch {
            print("❌ [Widget] Failed to fetch vehicles from context: \(error)")
            return nil
        }
    }
}
