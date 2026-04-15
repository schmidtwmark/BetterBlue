//
//  TemperatureDisplay.swift
//  BetterBlue
//
//  View-layer sanity check for vehicle-reported cabin/target temperatures.
//  Some API payloads (notably the Hyundai Canada sltvhcl endpoint for Gen3
//  Kona EVs) return a malformed `airTemp` block which, after passing through
//  the parser's `Temperature.minimum` fallback, lands on disk as
//  `units: .celsius, value: 62.0` — i.e. "62°C", which is physically
//  impossible for a cabin reading and caused issue #30.
//
//  Rather than change the `Temperature` or `ClimateStatus` Codable shape
//  (which is persisted by SwiftData and rolling it has triggered painful
//  on-disk migrations), we detect suspicious readings purely at display
//  time and let the UI hide them.
//

import BetterBlueKit
import Foundation

extension Temperature {
    /// `true` when this reading is within a physically plausible range for
    /// a vehicle's cabin / target temperature, given the labelled units.
    /// `false` for NaN, infinities, and values outside a conservative
    /// envelope — those are almost always a parser fallback or a
    /// unit-label mismatch from the upstream API, not a real measurement.
    ///
    /// Thresholds are intentionally loose: real readings from parked cars
    /// in extreme weather can go well outside the HVAC control range, so
    /// we only reject values no real thermostat would ever report.
    var isPlausibleForDisplay: Bool {
        guard value.isFinite else { return false }
        switch units {
        case .celsius:
            // Cabin air can get hot in direct sun, but anything above ~60°C
            // (140°F) is a sensor fault or a mislabelled Fahrenheit value.
            return value >= -40 && value <= 60
        case .fahrenheit:
            return value >= -40 && value <= 140
        }
    }
}
