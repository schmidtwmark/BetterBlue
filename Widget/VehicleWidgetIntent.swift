//
//  VehicleWidgetIntent.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource =
        "Vehicle Widget Configuration"
    static var description = IntentDescription("Choose a vehicle for the widget")

    @Parameter(
        title: "Vehicle",
        description: "Select which vehicle this widget controls",
    )
    var vehicle: VehicleEntity?

    init(vehicle: VehicleEntity?) {
        self.vehicle = vehicle
    }

    init() {}
}

struct VehicleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation =
        "Vehicle"
    static var defaultQuery = VehicleQuery()

    var id: String
    var displayName: String
    var vin: String
    var isElectric: Bool
    var rangeText: String
    var batteryPercentage: Double?
    var backgroundColorName: String
    var timestamp: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    // Get the gradient colors for the selected background
    var backgroundGradient: [Color] {
        guard let background = BBVehicle.availableBackgrounds.first(where: {
            $0.name == backgroundColorName
        }) else {
            return BBVehicle.availableBackgrounds[0].gradient
        }
        return background.gradient
    }

    init(
        id: String,
        displayName: String,
        vin: String,
        isElectric: Bool,
        rangeText: String,
        batteryPercentage: Double?,
        timestamp: Date,
        backgroundColorName: String = "default",
    ) {
        self.id = id
        self.displayName = displayName
        self.vin = vin
        self.isElectric = isElectric
        self.rangeText = rangeText
        self.batteryPercentage = batteryPercentage
        self.timestamp = timestamp
        self.backgroundColorName = backgroundColorName
    }

    init(from bbVehicle: BBVehicle, with unit: Distance.Units) {
        id = bbVehicle.id.uuidString
        displayName = bbVehicle.displayName
        vin = bbVehicle.vin
        isElectric = bbVehicle.isElectric
        backgroundColorName = bbVehicle.backgroundColorName
        timestamp = bbVehicle.lastUpdated ?? Date()

        // Use safe property accessors to prevent context detachment
        if bbVehicle.isElectric {
            if bbVehicle.modelContext != nil, let evStatus = bbVehicle.evStatus {
                batteryPercentage = evStatus.evRange.percentage
                let range = evStatus.evRange.range.length > 0 ?
                    evStatus.evRange.range.units.format(
                        evStatus.evRange.range.length,
                        to: unit,
                    ) : "--"
                rangeText = range
            } else {
                batteryPercentage = nil
                rangeText = "No EV data"
            }
        } else {
            if bbVehicle.modelContext != nil, let gasRange = bbVehicle.gasRange {
                batteryPercentage = gasRange.percentage
                let range = gasRange.range.length > 0 ?
                    gasRange.range.units.format(
                        gasRange.range.length,
                        to: unit,
                    ) : "--"
                rangeText = range
            } else {
                batteryPercentage = nil
                rangeText = "No fuel data"
            }
        }
    }
}

struct VehicleQuery: EntityQuery {
    func entities(
        for identifiers: [String],
    ) async throws -> [VehicleEntity] {
        try await MainActor.run {
            let modelContainer = try createSharedModelContainer()
            let context = ModelContext(modelContainer)

            let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
            let settings = AppSettings.shared

            return vehicles
                .filter { identifiers.contains($0.id.uuidString) }
                .map { VehicleEntity(from: $0, with: settings.preferredDistanceUnit) }
        }
    }

    func suggestedEntities() async throws -> [VehicleEntity] {
        try await MainActor.run {
            let modelContainer = try createSharedModelContainer()
            let context = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<BBVehicle>(
                predicate: #Predicate { !$0.isHidden },
                sortBy: [SortDescriptor(\.sortOrder)],
            )

            let vehicles = try context.fetch(descriptor)
            let settings = AppSettings.shared

            return vehicles.map { VehicleEntity(from: $0, with: settings.preferredDistanceUnit) }
        }
    }
}
