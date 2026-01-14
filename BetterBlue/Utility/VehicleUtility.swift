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
            isElectric: isElectric,
            generation: generation,
            odometer: odometer,
            vehicleKey: vehicleKey,
        )
    }
}
