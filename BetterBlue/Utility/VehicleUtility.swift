//
//  VehicleUtility.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/17/25.
//

import BetterBlueKit
import MapKit

extension BBVehicle {
    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude,
        )
    }

    var debugDescription: String {
        var components: [String] = []

        components.append("=== BBVehicle Debug Info ===")
        components.append("ID: \(id)")
        components.append("VIN: \(vin)")
        components.append("Model: \(model)")
        components.append("Display Name: \(displayName)")
        components.append("Electric: \(isElectric)")
        components.append("Generation: \(generation)")
        components.append("Account ID: \(accountId)")
        components.append("RegID: \(regId)")
        components.append("Hidden: \(isHidden)")
        components.append("Sort Order: \(sortOrder)")
        components.append("Background Color: \(backgroundColorName)")
        components.append("Watch Background Color: \(watchBackgroundColorName)")

        if let customName = customName {
            components.append("Custom Name: \(customName)")
        }

        components.append("Odometer: \(odometer.length) \(odometer.units)")

        if let lastUpdated = lastUpdated {
            components.append("Last Updated: \(lastUpdated)")
        } else {
            components.append("Last Updated: Never")
        }

        if let syncDate = syncDate {
            components.append("Sync Date: \(syncDate)")
        } else {
            components.append("Sync Date: Never")
        }

        if let gasRange = gasRange {
            components.append("Gas Range: \(gasRange.range.length) \(gasRange.range.units)")
            components.append("Gas Level: \(Int(gasRange.percentage))%")
        }

        if let evStatus = evStatus {
            components.append("EV Battery: \(Int(evStatus.evRange.percentage))%")
            components.append("EV Range: \(evStatus.evRange.range.length) \(evStatus.evRange.range.units)")
            components.append("EV Charging: \(evStatus.charging)")
            components.append("EV Plugged In: \(evStatus.pluggedIn)")
            if evStatus.chargeSpeed > 0 {
                components.append("Charge Speed: \(evStatus.chargeSpeed) kW")
            }
        }

        if let location = location {
            components.append("Location: \(location.latitude), \(location.longitude)")
        }

        if let lockStatus = lockStatus {
            components.append("Doors Locked: \(lockStatus == .locked)")
        }

        if let climateStatus = climateStatus {
            components.append("Climate On: \(climateStatus.airControlOn)")
            components.append("Climate Temp: \(climateStatus.temperature.value)°\(climateStatus.temperature.units)")
        }

        components.append("Climate Presets: \(safeClimatePresets.count)")

        if vehicleKey != nil {
            components.append("Vehicle Key: [Present]")
        }

        if debugConfiguration != nil {
            components.append("Debug Config: [Present]")
        }

        components.append("===========================")

        return components.joined(separator: "\n")
    }

    func toVehicle() -> Vehicle {
        Vehicle(
            vin: vin,
            regId: regId,
            model: model,
            accountId: accountId,
            isElectric: isElectric,
            generation: generation,
            odometer: odometer,
            vehicleKey: vehicleKey,
        )
    }
}
