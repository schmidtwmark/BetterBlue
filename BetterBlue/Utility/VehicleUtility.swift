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
    /// Whether this vehicle is still in the store. One that the main
    /// context deleted and saved (`BBAccount.updateVehicles` dropping a VIN
    /// the API no longer lists) reads `isDeleted == false` but has lost its
    /// context — and reading a Codable attribute it hadn't loaded yet
    /// (`marketOptions`, say) then traps in SwiftData.
    var isLive: Bool { !isDeleted && modelContext != nil }

    /// `toVehicle()` for code that has awaited since it got this vehicle:
    /// a vehicle removed in the meantime throws `CancellationError` — the
    /// work is moot, not failed — instead of trapping. Check and read happen
    /// together on the main actor, so nothing can delete it in between.
    @MainActor
    func liveVehicle() throws -> Vehicle {
        guard isLive else { throw CancellationError() }
        return toVehicle()
    }

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
            marketOptions: marketOptions,
            modelYear: modelYear
        )
    }
}
