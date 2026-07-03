//
//  VehicleUtility.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/17/25.
//

import BetterBlueKit
import Foundation
import MapKit
import SwiftData
import UIKit

extension BBVehicle {
    var coordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        // (0, 0) — null island — is what the APIs store when the vehicle
        // has no GPS fix. Treat it as "no location" so the map shows the
        // missing-location fallback instead of the Atlantic Ocean.
        guard location.latitude != 0 || location.longitude != 0 else { return nil }
        return CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude,
        )
    }

    func toVehicle() -> Vehicle {
        Vehicle(
            vin: vin,
            regId: regId,
            model: model,
            accountId: accountId,
            fuelType: fuelType,
            generation: generation,
            odometer: odometer,
            vehicleKey: vehicleKey,
            marketOptions: marketOptions
        )
    }
}
