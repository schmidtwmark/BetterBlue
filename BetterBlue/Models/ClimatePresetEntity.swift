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
        return fetchPresets(predicate: nil)
    }
    
    static func fetchPresets(withIDs ids: [UUID]) -> [ClimatePresetEntity] {
        return fetchPresets(predicate: #Predicate<ClimatePreset> { ids.contains($0.id) })
    }
    
    static func fetchPresets(predicate: Predicate<ClimatePreset>?) -> [ClimatePresetEntity] {
        do {
            let modelContainer = try createSharedModelContainer()
            let context = ModelContext(modelContainer)
            
            let descriptor = FetchDescriptor<ClimatePreset>(predicate: predicate)
            let presets = try context.fetch(descriptor)
            
            // Sort by Vehicle Sort Order -> Preset Sort Order
            let sortedPresets = presets.sorted { (lhs, rhs) -> Bool in
                if let vL = lhs.vehicle, let vR = rhs.vehicle {
                    if vL.sortOrder != vR.sortOrder {
                        return vL.sortOrder < vR.sortOrder
                    }
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            
            return sortedPresets.compactMap { preset in
                guard let vehicle = preset.vehicle else { return nil }
                
                return ClimatePresetEntity(
                    id: preset.id,
                    vehicleVin: vehicle.vin,
                    vehicleName: vehicle.displayName,
                    presetName: preset.name
                )
            }
        } catch {
            print("Failed to fetch presets: \(error)")
            return []
        }
    }
}