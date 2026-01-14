//
//  VehicleRangeViews.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import SwiftUI

struct EVRangeCardView: View {
    let evStatus: VehicleStatus.EVStatus
    @State private var appSettings = AppSettings.shared

    var formattedRange: String {
        guard evStatus.evRange.range.length > 0 else {
            return "--"
        }
        return evStatus.evRange.range.units.format(
            evStatus.evRange.range.length,
            to: appSettings.preferredDistanceUnit,
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("EV Range")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formattedRange)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("Battery")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Int(evStatus.evRange.percentage))%")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .vehicleCardGlassEffect()
    }
}

struct GasRangeCardView: View {
    let gasRange: VehicleStatus.FuelRange
    @State private var appSettings = AppSettings.shared

    var formattedRange: String {
        guard gasRange.range.length > 0 else {
            return "--"
        }
        return gasRange.range.units.format(
            gasRange.range.length,
            to: appSettings.preferredDistanceUnit,
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Gas Range")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formattedRange)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("Fuel")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Int(gasRange.percentage))%")
                    .font(.title3)
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .vehicleCardGlassEffect()
    }
}
