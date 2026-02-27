import AppIntents
import BetterBlueKit
import SwiftData

struct ClimatePresetEntity: AppEntity, Sendable {
    var id: UUID

    var vehicleVin: String
    var vehicleName: String
    var presetName: String
    var presetIcon: String
    var isSelected: Bool

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Climate Preset"
    static let defaultQuery = ClimatePresetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(vehicleName) - \(presetName)")
    }
}

struct ClimatePresetQuery: EntityQuery {
    func entities(for identifiers: [ClimatePresetEntity.ID]) async throws -> [ClimatePresetEntity] {
        return await ClimatePresetFetcher.fetchPresets(withIDs: identifiers)
    }

    func suggestedEntities() async throws -> [ClimatePresetEntity] {
        return await ClimatePresetFetcher.fetchAllPresets()
    }
}

@MainActor
private struct ClimatePresetFetcher {
    static func fetchAllPresets() -> [ClimatePresetEntity] {
        return fetchPresets(withIDs: nil)
    }

    static func fetchPresets(withIDs ids: [UUID]?) -> [ClimatePresetEntity] {
        do {
            let modelContainer = try createSharedModelContainer()
            let context = ModelContext(modelContainer)

            // Fetch all presets directly (like @Query does)
            let presetDescriptor = FetchDescriptor<ClimatePreset>(sortBy: [SortDescriptor(\.sortOrder)])
            let allPresets = try context.fetch(presetDescriptor)

            // Fetch all vehicles to identify those without presets
            let vehicleDescriptor = FetchDescriptor<BBVehicle>(sortBy: [SortDescriptor(\.sortOrder)])
            let allVehicles = try context.fetch(vehicleDescriptor)

            var entities: [ClimatePresetEntity] = []

            // Track which vehicles have presets
            var vehiclesWithPresets = Set<UUID>()

            // Process actual presets
            for preset in allPresets {
                guard let vehicle = preset.vehicle else { continue }
                vehiclesWithPresets.insert(vehicle.id)

                if ids == nil || ids!.contains(preset.id) {
                    entities.append(ClimatePresetEntity(
                        id: preset.id,
                        vehicleVin: vehicle.vin,
                        vehicleName: vehicle.displayName,
                        presetName: preset.name,
                        presetIcon: preset.iconName,
                        isSelected: preset.isSelected
                    ))
                }
            }

            // Add default presets for vehicles without any presets
            for vehicle in allVehicles where !vehiclesWithPresets.contains(vehicle.id) {
                if ids == nil || ids!.contains(vehicle.id) {
                    entities.append(ClimatePresetEntity(
                        id: vehicle.id,
                        vehicleVin: vehicle.vin,
                        vehicleName: vehicle.displayName,
                        presetName: "Default",
                        presetIcon: "fan",
                        isSelected: true
                    ))
                }
            }

            return entities
        } catch {
            BBLogger.error(.app, "Failed to fetch presets: \(error)")
            return []
        }
    }

    // Helper to resolve just the vehicle VIN from a preset ID (which might be a vehicle ID for default)
    static func getVehicleId(for presetId: UUID) async -> String? {
        let allEntities = fetchPresets(withIDs: [presetId])
        return allEntities.first?.vehicleVin
    }
}
