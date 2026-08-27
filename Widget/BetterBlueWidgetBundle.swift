//
//  BetterBlueWidgetBundle.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct BetterBlueWidgetBundle: WidgetBundle {
    var body: some Widget {
        BetterBlueWidget()
        BetterBlueLockScreenWidget()
        BetterBlueLockScreenRangeWidget()
        VehicleLockControlWidget()
        VehicleUnlockControlWidget()
        ClimateStartControlWidget()
        ClimateStopControlWidget()
        StartChargeControlWidget()
        StopChargeControlWidget()
        SurroundViewControlWidget()
        VehicleActivityWidget()
    }
}
