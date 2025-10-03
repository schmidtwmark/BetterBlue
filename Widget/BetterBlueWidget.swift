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
            VehicleWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    if let vehicle = entry.vehicle {
                        LinearGradient(
                            gradient: Gradient(colors: vehicle.backgroundGradient),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing,
                        )
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
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
        .configurationDisplayName("Vehicle Range")
        .description("Shows your vehicle's current range as a circular indicator.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
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
                if let vehicle = intent.vehicle, !vehicle.id.isEmpty {
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
                if let vehicle = intent.vehicle, !vehicle.id.isEmpty {
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
                if let vehicle = intent.vehicle, !vehicle.id.isEmpty {
                    Label("Start Climate", systemImage: "thermometer.sun.fill")
                } else {
                    Label("Select Vehicle", systemImage: "thermometer.sun.fill")
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
                if let vehicle = intent.vehicle, !vehicle.id.isEmpty {
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
