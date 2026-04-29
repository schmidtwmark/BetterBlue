//
//  MenuBarPanelContent.swift
//  BetterBlueMac
//
//  SwiftUI view rendered inside the `MenuBarExtra` window. Builds one
//  card per non-hidden vehicle using the same components the
//  iPhone/iPad main view uses — `VehicleTitleView`, `EVRangeDisplayCard`,
//  `GasRangeCardView`, `ChargingButton`, `LockButton`, `ClimateButton` —
//  so the menu bar matches the rest of the app pixel-for-pixel rather
//  than being a separate AppKit panel that has to be visually
//  re-synced every time the main view changes.
//
//  The "shared" part is target-membership-based: this file is in the
//  `BetterBlueMac/` folder (macOS-target only), but the components it
//  uses live in the `BetterBlue/` folder which has been added to the
//  macOS target's membership-exception set in `project.pbxproj`. So
//  the same Swift file backs both the iPhone main view's lock button
//  and the menu bar's lock button.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct MenuBarPanelContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<BBVehicle> { !$0.isHidden },
        sort: \BBVehicle.sortOrder
    ) private var vehicles: [BBVehicle]

    @Query private var accounts: [BBAccount]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if vehicles.isEmpty {
                    emptyState
                } else {
                    ForEach(vehicles) { vehicle in
                        VehicleMenuBarCard(
                            bbVehicle: vehicle,
                            allVehicles: vehicles,
                            accounts: accounts
                        )
                        // VIN identity so SwiftUI rebuilds per-card
                        // state cleanly when the list changes.
                        .id(vehicle.vin)
                    }
                }

                Divider()

                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open BetterBlue", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
        }
        // Fixed width and height. Without an explicit height the
        // `MenuBarExtra(.window)` popover sizes itself to SwiftUI's
        // reported intrinsic height — which inside a `ScrollView`
        // collapses to ~0 because ScrollView reports ideal height of
        // zero. A fixed height keeps the popover at a useful size and
        // lets the ScrollView handle overflow.
        .frame(width: 380, height: 520)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "car.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No vehicles")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// One vehicle's controls in the menu bar panel. Uses the same
/// component composition as `VehicleCardView` — header with refresh,
/// EV range card / gas range card, charging button, lock button,
/// climate button — but without the outer card / map context.
private struct VehicleMenuBarCard: View {
    let bbVehicle: BBVehicle
    let allVehicles: [BBVehicle]
    let accounts: [BBAccount]

    @Namespace private var transition

    var body: some View {
        VStack(spacing: 8) {
            VehicleTitleView(
                bbVehicle: bbVehicle,
                bbVehicles: allVehicles,
                onVehicleSelected: { _ in /* no selection in menu bar */ },
                accounts: accounts,
                transition: transition,
                onRefresh: nil
            )

            if let evStatus = bbVehicle.evStatus {
                EVRangeDisplayCard(evStatus: evStatus)
            }

            if bbVehicle.evStatus != nil {
                ChargingButton(bbVehicle: bbVehicle, transition: transition)
            }

            if let gasRange = bbVehicle.gasRange {
                GasRangeCardView(gasRange: gasRange)
            }

            LockButton(bbVehicle: bbVehicle, transition: transition)
            ClimateButton(bbVehicle: bbVehicle, transition: transition)
        }
    }
}
