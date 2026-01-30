//
//  ClimatePreset.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/6/25.
//

import BetterBlueKit
import Foundation
import SwiftData

@Model
class ClimatePreset: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var iconName: String = ""
    var climateOptions: ClimateOptions = ClimateOptions()
    var isSelected: Bool = false
    var sortOrder: Int = 0
    var vehicleId: UUID = UUID()

    @Relationship(inverse: \BBVehicle.climatePresets) var vehicle: BBVehicle?

    static let availableIcons: [(icon: String, name: String)] = [
        ("fan", "Fan"),
        ("thermometer", "Thermometer"),
        ("snowflake", "Snowflake"),
        ("sun.max", "Sun"),
        ("wind", "Wind"),
        ("cloud.snow", "Snow")
    ]

    init(name: String,
         iconName: String = "fan",
         climateOptions: ClimateOptions,
         isSelected: Bool = false,
         vehicleId: UUID) {
        id = UUID()
        self.name = name
        self.iconName = iconName
        self.climateOptions = climateOptions
        self.isSelected = isSelected
        sortOrder = 0
        self.vehicleId = vehicleId
    }
}

// MARK: - Codable Conformance for Export

extension ClimatePreset: Encodable {
    enum CodingKeys: String, CodingKey {
        case id, name, iconName, climateOptions, isSelected, sortOrder, vehicleId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(iconName, forKey: .iconName)
        try container.encode(climateOptions, forKey: .climateOptions)
        try container.encode(isSelected, forKey: .isSelected)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(vehicleId, forKey: .vehicleId)
    }
}
