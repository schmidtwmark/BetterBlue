//
//  MenuBarRefreshManager.swift
//  BetterBlue
//
//  Periodic polling loop for the Mac menu bar app. Runs on the same
//  cadence as `AppSettings.widgetRefreshInterval`, refreshing every
//  non-hidden vehicle and tagging the resulting HTTP logs as
//  `DeviceType.menuBar` via `HTTPLogContext.$overrideDeviceType`.
//
//  macOS only. Lifecycle is tied to the `BetterBlueMacApp`'s
//  `MenuBarExtra` scene activation.
//

#if os(macOS)

import BetterBlueKit
import Foundation
import SwiftData

@MainActor
final class MenuBarRefreshManager {
    static let shared = MenuBarRefreshManager()

    private var modelContainer: ModelContainer?
    private var timer: Timer?
    /// Track the current interval so `start()` is idempotent when the
    /// user's preference hasn't changed.
    private var currentIntervalSeconds: TimeInterval?
    private var isRefreshing = false

    private init() {}

    // MARK: - Lifecycle

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Start (or restart) the timer using the user's current
    /// `widgetRefreshInterval`. Safe to call repeatedly — if the interval
    /// hasn't changed the existing timer is left in place.
    func start() {
        let interval = AppSettings.shared.widgetRefreshInterval.timeInterval
        if let timer, timer.isValid, currentIntervalSeconds == interval {
            return
        }

        stop()
        currentIntervalSeconds = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }

        // Fire once immediately so the menu bar has fresh data right after
        // the user enables it, rather than waiting up to a full interval.
        Task { @MainActor in
            await tick()
        }

        BBLogger.info(.app, "MenuBarRefresh: Started with interval \(Int(interval))s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentIntervalSeconds = nil
        BBLogger.info(.app, "MenuBarRefresh: Stopped")
    }

    /// Call when `AppSettings.widgetRefreshInterval` changes so the timer
    /// adopts the new cadence without requiring an app restart.
    func intervalDidChange() {
        guard timer != nil else { return } // not running
        start()
    }

    // MARK: - Refresh tick

    private func tick() async {
        guard !isRefreshing, let container = modelContainer else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<BBVehicle>(predicate: #Predicate { !$0.isHidden })
        let vehicles: [BBVehicle]
        do {
            vehicles = try context.fetch(descriptor)
        } catch {
            BBLogger.error(.app, "MenuBarRefresh: Failed to fetch vehicles: \(error)")
            return
        }

        // Tag every HTTP request made by this tick as `.menuBar`. The sink
        // closure in `HTTPLogSinkManager.createLogSink(for:)` captures the
        // TaskLocal value synchronously when each request completes, so
        // every call inside this `withValue` block gets the override.
        await HTTPLogContext.$overrideDeviceType.withValue(.menuBar) {
            for vehicle in vehicles {
                guard let account = vehicle.account else { continue }
                do {
                    try await account.fetchAndUpdateVehicleStatus(
                        for: vehicle,
                        modelContext: context,
                        cached: false
                    )
                } catch {
                    BBLogger.warning(
                        .app,
                        "MenuBarRefresh: Refresh failed for \(vehicle.vin): \(error)"
                    )
                }
            }
        }
    }
}

#endif
