//
//  BetterBlueWidget.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct BetterBlueWidget: Widget {
    let kind: String = "BetterBlueWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VehicleWidgetIntent.self,
            provider: VehicleTimelineProvider(),
        ) { entry in
            // Background is set inside VehicleWidgetEntryView (honoring
            // the configured override + the adaptive Default). Declaring
            // a second containerBackground here would conflict with it.
            VehicleWidgetEntryView(entry: entry)
        }
        .contentMarginsDisabled() // Here
        .configurationDisplayName("Vehicle Control")
        .description("Quick controls for your vehicle. Use Edit Widget to select a different vehicle.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BetterBlueLockScreenWidget: Widget {
    let kind: String = "BetterBlueLockScreenWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VehicleWidgetIntent.self,
            provider: VehicleTimelineProvider(),
        ) { entry in
            LockScreenVehicleWidgetView(entry: entry)
        }
        .configurationDisplayName("Vehicle Percentage")
        .description("Battery or fuel ring with the percentage. The rectangular size adds the vehicle name and range.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

/// Circular ring with the remaining RANGE in the center instead of the
/// percentage. Its own widget kind (rather than an option on
/// BetterBlueLockScreenWidget) so both variants appear in the gallery
/// and existing placements upgrade in place without reconfiguration.
struct BetterBlueLockScreenRangeWidget: Widget {
    let kind: String = "BetterBlueLockScreenRangeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VehicleWidgetIntent.self,
            provider: VehicleTimelineProvider(),
        ) { entry in
            LockScreenVehicleWidgetView(entry: entry, circularCenter: .range)
        }
        .configurationDisplayName("Vehicle Range")
        .description("Battery or fuel ring with the remaining range.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Control Center Widgets

@available(iOS 18, *)
struct VehicleLockControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.lock",
            intent: LockVehicleControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if let vehicle = intent.vehicle {
                    Label("Lock \(vehicle.displayName)", systemImage: "lock.fill")
                } else {
                    Label("Select Vehicle", systemImage: "lock.fill")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Lock Vehicle")
        .description("Lock your vehicle from Control Center")
    }
}

@available(iOS 18, *)
struct VehicleUnlockControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.unlock",
            intent: UnlockVehicleControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if let vehicle = intent.vehicle {
                    Label("Unlock \(vehicle.displayName)", systemImage: "lock.open.fill")
                } else {
                    Label("Select Vehicle", systemImage: "lock.open.fill")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Unlock Vehicle")
        .description("Unlock your vehicle from Control Center")
    }
}

@available(iOS 18, *)
struct ClimateStartControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.climate.start",
            intent: StartClimateControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if let preset = intent.preset {
                    Label("Start \(preset.vehicleName) - \(preset.presetName)", systemImage: "thermometer.sun.fill")
                } else {
                    Label("Select Preset", systemImage: "thermometer.snowflake")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Start Climate")
        .description("Start climate control from Control Center")
    }
}

@available(iOS 18, *)
struct ClimateStopControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.climate.stop",
            intent: StopClimateControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if intent.vehicle != nil {
                    Label("Stop Climate", systemImage: "thermometer.snowflake")
                } else {
                    Label("Select Vehicle", systemImage: "thermometer.snowflake")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Stop Climate")
        .description("Stop climate control from Control Center")
    }
}

@available(iOS 18, *)
struct StartChargeControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.charge.start",
            intent: StartChargeControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if intent.vehicle != nil {
                    Label("Start Charge", systemImage: "bolt.fill")
                } else {
                    Label("Select Vehicle", systemImage: "bolt.fill")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Start Charge")
        .description("Start charging from Control Center")
    }
}

@available(iOS 18, *)
struct StopChargeControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: "com.betterblue.charge.stop",
            intent: StopChargeControlIntent.self
        ) { intent in
            ControlWidgetButton(action: intent) {
                if intent.vehicle != nil {
                    Label("Stop Charge", systemImage: "bolt.slash.fill")
                } else {
                    Label("Select Vehicle", systemImage: "bolt.slash.fill")
                }
            }
        }
        .promptsForUserConfiguration()
        .displayName("Stop Charge")
        .description("Stop charging from Control Center")
    }
}
