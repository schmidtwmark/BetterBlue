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
        // Hoist the work that doesn't need SwiftData — `preferredUnit`
        // is a UserDefaults read, `allPresets` opens its *own* short-
        // lived container internally. Doing them outside our main
        // container scope means no overlap on SQLite handles while we
        // pump them.
        let unit = await MainActor.run { AppSettings.shared.preferredDistanceUnit }
        let allPresets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []

        do {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)

            // Configure the HTTP log sink manager for widget — must
            // share the same container so log writes land in the
            // right store. Done once before the per-call scope opens.
            await MainActor.run {
                HTTPLogSinkManager.shared.configure(with: modelContainer, deviceType: .widget)
            }

            return try await refreshEntity(
                for: configuration,
                container: modelContainer,
                unit: unit,
                allPresets: allPresets
            )
        } catch {
            BBLogger.error(.app, "Widget: Failed to refresh vehicle data: \(error)")

            // Fall back to cached data with a fresh container so the
            // failed one's open transactions (if any) are torn down.
            do {
                let modelContainer = try createSharedModelContainer(enableCloudKit: false)
                await MainActor.run {
                    HTTPLogSinkManager.shared.configure(with: modelContainer, deviceType: .widget)
                }
                return cachedEntity(
                    for: configuration,
                    container: modelContainer,
                    unit: unit,
                    allPresets: allPresets
                )
            } catch {
                BBLogger.error(.app, "Widget: Failed to get cached vehicle data: \(error)")
                return nil
            }
        }
    }

    /// Per-timeline-call SwiftData scope. Opens a fresh `ModelContext`,
    /// fetches the configured vehicle, conditionally refreshes it via
    /// HTTP (if the cached status is older than 30 minutes), saves
    /// explicitly, and returns the assembled `VehicleEntity`. The
    /// context goes out of scope as soon as this returns so SwiftData
    /// drops its change-tracking state and SQLite's per-context locks
    /// release before WidgetKit measures our runtime budget.
    ///
    /// Holding the context across the HTTP boundary is unavoidable
    /// here because `BBAccount.fetchAndUpdateVehicleStatus` takes a
    /// `ModelContext` for HTTP logging + token persistence. Keeping
    /// the scope as tight as possible — one vehicle per call, explicit
    /// save at the end — minimises the RunningBoard 0xdead10cc risk
    /// when the widget process is yanked mid-fetch.
    private func refreshEntity(
        for configuration: VehicleWidgetIntent,
        container: ModelContainer,
        unit: Distance.Units,
        allPresets: [ClimatePresetEntity]
    ) async throws -> VehicleEntity? {
        let context = ModelContext(container)

        guard let bbVehicle = fetchTargetVehicle(for: configuration, context: context) else {
            BBLogger.info(.app, "Widget: No vehicle found for refresh")
            return nil
        }
        guard let account = bbVehicle.account else {
            BBLogger.info(.app, "Widget: Vehicle has no account, returning cached entity")
            return VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)
        }

        let vehicleName = bbVehicle.displayName
        let lastUpdated = bbVehicle.lastUpdated ?? Date.distantPast
        let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdated)
        let thirtyMinutesInSeconds: TimeInterval = 30 * 60

        if timeSinceLastUpdate < thirtyMinutesInSeconds {
            BBLogger.info(
                .app,
                "Widget: Using fresh data for \(vehicleName) (updated \(Int(timeSinceLastUpdate / 60))m ago)"
            )
        } else {
            BBLogger.info(
                .app,
                "Widget: Refreshing stale vehicle status for \(vehicleName) " +
                "(last updated \(Int(timeSinceLastUpdate / 60))m ago)"
            )

            try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)
            // `fetchAndUpdateVehicleStatus` saves internally, but be
            // belt-and-suspenders explicit so any side-effect writes
            // we made on `bbVehicle` flush before the context drops.
            try context.save()

            BBLogger.info(.app, "Widget: Successfully refreshed \(vehicleName)")
        }

        return VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)
    }

    /// Cached-only path (no HTTP). Same tight-scope pattern as
    /// `refreshEntity` — fetch, build entity, drop context.
    private func cachedEntity(
        for configuration: VehicleWidgetIntent,
        container: ModelContainer,
        unit: Distance.Units,
        allPresets: [ClimatePresetEntity]
    ) -> VehicleEntity? {
        let context = ModelContext(container)
        guard let bbVehicle = fetchTargetVehicle(for: configuration, context: context) else {
            return nil
        }
        return VehicleEntity(from: bbVehicle, with: unit, allPresets: allPresets)
    }

    /// Shared lookup: configured vehicle by VIN if the user picked
    /// one, otherwise the first non-hidden vehicle by sort order.
    private func fetchTargetVehicle(
        for configuration: VehicleWidgetIntent,
        context: ModelContext
    ) -> BBVehicle? {
        do {
            if let configVehicle = configuration.vehicle {
                let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
                return vehicles.first { $0.vin == configVehicle.vin }
            } else {
                let descriptor = FetchDescriptor<BBVehicle>(
                    predicate: #Predicate { !$0.isHidden },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
                return try context.fetch(descriptor).first
            }
        } catch {
            BBLogger.error(.app, "Widget: Failed to fetch vehicles from context: \(error)")
            return nil
        }
    }

}
