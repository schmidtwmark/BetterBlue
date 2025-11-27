import AppIntents
import SwiftData

struct ClimatePresetEntity: AppEntity, Sendable {
    var id: UUID
    
    var vehicleVin: String
    var vehicleName: String
    var presetName: String

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
            
            let descriptor = FetchDescriptor<BBVehicle>(sortBy: [SortDescriptor(\.sortOrder)])
            let vehicles = try context.fetch(descriptor)
            
            var entities: [ClimatePresetEntity] = []
            
            for vehicle in vehicles {
                let presets = vehicle.safeClimatePresets.sorted { $0.sortOrder < $1.sortOrder }
                
                if presets.isEmpty {
                    // Create Default preset using vehicle ID as the entity ID
                    if ids == nil || ids!.contains(vehicle.id) {
                        entities.append(ClimatePresetEntity(
                            id: vehicle.id,
                            vehicleVin: vehicle.vin,
                            vehicleName: vehicle.displayName,
                            presetName: "Default"
                        ))
                    }
                } else {
                    for preset in presets {
                        if ids == nil || ids!.contains(preset.id) {
                            entities.append(ClimatePresetEntity(
                                id: preset.id,
                                vehicleVin: vehicle.vin,
                                vehicleName: vehicle.displayName,
                                presetName: preset.name
                            ))
                        }
                    }
                }
            }
            
            return entities
        } catch {
            print("Failed to fetch presets: \(error)")
            return []
        }
    }
    
    // Helper to resolve just the vehicle ID from a preset ID (which might be a vehicle ID for default)
    static func getVehicleId(for presetId: UUID) async -> String? {
        // This logic is implicitly handled by the Intent which gets the full Entity back.
        // But StartClimateIntent uses this helper. We need to update it or StartClimateIntent.
        // StartClimateIntent uses: ClimatePresetFetcher.getVehicleId(for: preset.id)
        // We should implement this efficiently.
        
        let allEntities = fetchPresets(withIDs: [presetId])
        return allEntities.first?.vehicleVin // We stored VIN in the entity
    }
}
