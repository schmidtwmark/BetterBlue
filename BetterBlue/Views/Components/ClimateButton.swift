//
//  ClimateButton.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct ClimateButton: View {
    let bbVehicle: BBVehicle
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var showingSettings = false
    @State private var appSettings = AppSettings.shared
    @Query private var allClimatePresets: [ClimatePreset]

    private var filteredPresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicle?.id == bbVehicle.id }
    }

    private var selectedPreset: ClimatePreset? {
        filteredPresets.first { $0.isSelected }
    }

    private var effectivePreset: ClimatePreset? {
        selectedPreset ?? filteredPresets.first
    }

    var isClimateOn: Bool {
        guard bbVehicle.modelContext != nil else {
            BBLogger.warning(.app, "ClimateButton: BBVehicle \(bbVehicle.vin) is detached from context")
            return false
        }
        return bbVehicle.climateStatus?.airControlOn ?? false
    }

    var climateRunningText: String {
        guard bbVehicle.modelContext != nil else { return "" }
        if isClimateOn, let climateStatus = bbVehicle.climateStatus {
            let formattedTemp = climateStatus.temperature.units.format(
                climateStatus.temperature.value,
                to: appSettings.preferredTemperatureUnit,
            )
            return "Running at \(formattedTemp)"
        }
        return ""
    }

    var climateStartedText: String {
        guard let preset = effectivePreset else { return "Climate started" }
        let formattedTemp = preset.climateOptions.temperature.units.format(
            preset.climateOptions.temperature.value,
            to: appSettings.preferredTemperatureUnit,
        )

        return "Started at \(formattedTemp)"
    }

    nonisolated func showSettings() {
        Task { @MainActor in showingSettings = true }
    }

    var body: some View {
        let startClimate = MainVehicleAction(
            action: { statusUpdater in
                try await setClimate(true, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "fan.slash"),
            label: "Start Climate",
            inProgressLabel: "Starting Climate",
            completedText: climateStartedText,
            color: .secondary,
            stateLabel: "Climate Off",
            quickActionColor: .blue,
            menuIcon: Image(systemName: "fan")
        )

        let stopClimate = MainVehicleAction(
            action: { statusUpdater in
                try await setClimate(false, statusUpdater: statusUpdater)
            },
            icon: Image(systemName: "fan"),
            label: "Stop Climate",
            inProgressLabel: "Stopping Climate",
            completedText: "Climate control stopped",
            color: .blue,
            stateLabel: climateRunningText.isEmpty ? "Climate Running" : climateRunningText,
            quickActionColor: .secondary,
            shouldRotate: true,
            menuIcon: Image(systemName: "fan.slash")
        )

        let showClimateSettings = MenuVehicleAction(
            action: { _ in showSettings() },
            icon: Image(systemName: "gearshape.fill"),
            label: "Climate Settings"
        )

        let startPresets = filteredPresets.filter { !$0.isSelected }.map { preset in
            let options = preset.climateOptions
            return MenuVehicleAction(
                action: { statusUpdater in
                    try await setClimate(
                        true,
                        statusUpdater: statusUpdater,
                        options: options,
                    )
                },
                icon: Image(systemName: preset.iconName),
                label: "Start \(preset.name)"
            )
        }

        VehicleControlButton(
            actions: [startClimate, stopClimate] + startPresets + [showClimateSettings],
            currentActionDeterminant: { isClimateOn ? stopClimate : startClimate },
            transition: transition,
            bbVehicle: bbVehicle,
        )
        .sheet(isPresented: $showingSettings) {
            ClimateSettingsSheet(vehicle: bbVehicle)
        }
    }

    @MainActor
    private func setClimate(
        _ shouldStart: Bool,
        statusUpdater: @escaping @Sendable (String) -> Void,
        options: ClimateOptions? = nil,
    ) async throws {
        guard let account = bbVehicle.account else {
            throw APIError(message: "Account not found for vehicle")
        }

        let context = modelContext

        if shouldStart {
            let climateOptions = options ??
                effectivePreset?.climateOptions ??
                ClimateOptions()
            try await account.startClimate(
                bbVehicle,
                options: climateOptions,
                modelContext: context,
                presetName: effectivePreset?.name,
                presetIcon: effectivePreset?.iconName
            )
        } else {
            try await account.stopClimate(bbVehicle, modelContext: context)

            // Immediately fetch status to update Live Activity
            // This ensures the Live Activity ends even if waitForStatusChange times out
            do {
                try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)
            } catch {
                BBLogger.warning(.app, "ClimateButton: Failed to fetch status after stop command: \(error)")
            }
        }

        try await bbVehicle.waitForStatusChange(
            modelContext: context,
            condition: { status in
                status.climateStatus.airControlOn == shouldStart
            },
            statusMessageUpdater: statusUpdater,
        )
    }
}
