//
//  VehicleTitleView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI

struct VehicleTitleView: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    let onVehicleSelected: (BBVehicle) -> Void
    let accounts: [BBAccount]
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared

    @State private var isExpanded = false
    @State private var showingVehicleInfo = false
    @State private var showingAccountInfo = false
    @State private var showingHTTPLogs = false
    @State private var showingVehicleConfiguration = false
    @State private var showingTripDetails = false
    @State private var customVehicleName = ""
    @Namespace private var fallbackTransition

    private var vehicleAccount: BBAccount? {
        bbVehicle.account
    }

    private var safeLocation: VehicleStatus.Location? {
        guard bbVehicle.modelContext != nil else {
            BBLogger.warning(.app, "VehicleTitleView: BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row (never animates)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bbVehicle.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    if let lastUpdated = bbVehicle.lastUpdated {
                        let timeString = formatLastUpdated(lastUpdated)
                        if timeString != "" {
                            Text(timeString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .animation(nil, value: isExpanded)

            // Expanded content
            if isExpanded {
                expandedContent
            }
        }
        .padding()
        .vehicleCardGlassEffect()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .sheet(isPresented: $showingVehicleInfo) {
            NavigationView {
                VehicleInfoView(
                    bbVehicle: bbVehicle,
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") {
                            showingVehicleInfo = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAccountInfo) {
            if let account = vehicleAccount {
                NavigationView {
                    AccountInfoView(
                        account: account,
                    )
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                showingAccountInfo = false
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingHTTPLogs) {
            if let account = vehicleAccount {
                NavigationView {
                    HTTPLogView(accountId: account.id, transition: transition)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") {
                                    showingHTTPLogs = false
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingVehicleConfiguration) {
            if bbVehicle.account?.brandEnum == .fake {
                NavigationView {
                    FakeVehicleDetailView(vehicle: bbVehicle)
                        .navigationTitle("Configure Vehicle")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") {
                                    showingVehicleConfiguration = false
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingTripDetails) {
            NavigationView {
                TripDetailsView(bbVehicle: bbVehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                showingTripDetails = false
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Odometer
            StatusInfoRow(
                icon: "speedometer",
                label: "Odometer",
                value: bbVehicle.odometer.units.format(
                    bbVehicle.odometer.length,
                    to: appSettings.preferredDistanceUnit
                )
            )

            // 12V Battery
            if let battery12V = bbVehicle.battery12V {
                StatusInfoRow(
                    icon: "batteryblock",
                    label: "12V Battery",
                    value: "\(battery12V)%",
                    valueColor: battery12V < 50 ? .orange : (battery12V < 30 ? .red : .primary)
                )
            }

            // Doors Status (car.top icons)
            if let doorOpen = bbVehicle.doorOpen {
                let doorStatus = buildDoorStatusText(doorOpen: doorOpen)
                let doorIcon = buildDoorIcon(doorOpen: doorOpen)
                StatusInfoRow(
                    icon: doorIcon,
                    label: "Doors",
                    value: doorStatus.text,
                    valueColor: doorStatus.isOpen ? .orange : .green
                )
            }

            // Hood/Trunk Status (car.side icons)
            HoodTrunkStatusRow(
                hoodOpen: bbVehicle.hoodOpen ?? false,
                trunkOpen: bbVehicle.trunkOpen ?? false
            )

            // Tire Pressure
            if let tirePressure = bbVehicle.tirePressureWarning {
                let tireStatus = buildTirePressureText(tirePressure: tirePressure)
                StatusInfoRow(
                    icon: tirePressure.hasWarning ? "exclamationmark.tirepressure" : "tirepressure",
                    label: "Tire Pressure",
                    value: tireStatus,
                    valueColor: tirePressure.hasWarning ? .orange : .green
                )
            }
        }
        .padding(.top, 4)
    }

    private func buildDoorStatusText(doorOpen: VehicleStatus.DoorStatus) -> (text: String, isOpen: Bool) {
        let openDoors: [(name: String, isOpen: Bool)] = [
            ("Front Left", doorOpen.frontLeft),
            ("Front Right", doorOpen.frontRight),
            ("Rear Left", doorOpen.backLeft),
            ("Rear Right", doorOpen.backRight)
        ]

        let openCount = openDoors.filter { $0.isOpen }.count

        if openCount == 0 {
            return ("All Closed", false)
        } else if openCount == 1 {
            let openDoor = openDoors.first { $0.isOpen }!
            return ("\(openDoor.name) open", true)
        } else {
            return ("\(openCount) Doors open", true)
        }
    }

    private func buildTirePressureText(tirePressure: VehicleStatus.TirePressureWarning) -> String {
        if !tirePressure.hasWarning {
            return "OK"
        }

        let lowTires: [(name: String, isLow: Bool)] = [
            ("Front Left", tirePressure.frontLeft),
            ("Front Right", tirePressure.frontRight),
            ("Rear Left", tirePressure.rearLeft),
            ("Rear Right", tirePressure.rearRight)
        ]

        let lowCount = lowTires.filter { $0.isLow }.count

        if tirePressure.all {
            return "All tires low"
        } else if lowCount == 1 {
            let lowTire = lowTires.first { $0.isLow }!
            return "\(lowTire.name) low"
        } else {
            return "\(lowCount) tires low"
        }
    }

    private func buildDoorIcon(doorOpen: VehicleStatus.DoorStatus) -> String {
        let fl = doorOpen.frontLeft
        let fr = doorOpen.frontRight
        let bl = doorOpen.backLeft
        let br = doorOpen.backRight

        // No doors open
        if !doorOpen.anyOpen {
            return "car.top"
        }

        // All four doors
        if fl && fr && bl && br {
            return "car.top.door.front.left.and.front.right.and.rear.left.and.rear.right.open"
        }

        // Three doors (various combinations)
        if fl && fr && bl { return "car.top.door.front.left.and.front.right.and.rear.left.open" }
        if fl && fr && br { return "car.top.door.front.left.and.front.right.and.rear.right.open" }
        if fl && bl && br { return "car.top.door.front.left.and.rear.left.and.rear.right.open" }
        if fr && bl && br { return "car.top.door.front.right.and.rear.left.and.rear.right.open" }

        // Two doors
        if fl && fr { return "car.top.door.front.left.and.front.right.open" }
        if bl && br { return "car.top.door.rear.left.and.rear.right.open" }
        if fl && bl { return "car.top.door.front.left.and.rear.left.open" }
        if fr && br { return "car.top.door.front.right.and.rear.right.open" }
        if fl && br { return "car.top.door.front.left.and.rear.right.open" }
        if fr && bl { return "car.top.door.front.right.and.rear.left.open" }

        // Single door
        if fl { return "car.top.door.front.left.open" }
        if fr { return "car.top.door.front.right.open" }
        if bl { return "car.top.door.rear.left.open" }
        if br { return "car.top.door.rear.right.open" }

        // Fallback
        return "car.top"
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if bbVehicles.count > 1 {
            Menu {
                ForEach(bbVehicles, id: \.id) { vehicle in
                    Button(action: {
                        onVehicleSelected(vehicle)
                    }, label: {
                        HStack {
                            Text(vehicle.displayName)
                            if vehicle.id == bbVehicle.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    })
                }
            } label: {
                Label("Switch Vehicles", systemImage: "iphone.app.switcher")
            }
        }

        if let location = safeLocation {
            let availableApps = NavigationHelper.availableMapApps
            let coordinate = CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            )
            let destinationName = bbVehicle.displayName

            if availableApps.count == 1 {
                Button {
                    NavigationHelper.navigate(
                        using: availableApps[0],
                        to: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            } else {
                Menu {
                    NavigationMenuContent(
                        coordinate: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            }
        }

        // Trip Details (only for Hyundai EVs)
        if bbVehicle.isElectric && vehicleAccount?.supportsEVTripDetails == true {
            Button {
                showingTripDetails = true
            } label: {
                Label("Trip History", systemImage: "chart.line.uptrend.xyaxis")
            }
        }

        Button {
            customVehicleName = bbVehicle.displayName
            showingVehicleInfo = true
        } label: {
            Label("Vehicle Info", systemImage: "car.fill")
        }

        Button {
            showingAccountInfo = true
        } label: {
            Label("Account Info", systemImage: "person.circle")
        }

        if AppSettings.shared.debugModeEnabled {
            Button {
                showingHTTPLogs = true
            } label: {
                Label("HTTP Logs", systemImage: "network")
            }
        }

        if bbVehicle.account?.brandEnum == .fake {
            Button {
                showingVehicleConfiguration = true
            } label: {
                Label("Configure Vehicle", systemImage: "gearshape.fill")
            }
        }
    }
}

// MARK: - Status Info Row

private struct StatusInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Hood/Trunk Status Row

private struct HoodTrunkStatusRow: View {
    let hoodOpen: Bool
    let trunkOpen: Bool

    private var statusText: String {
        if hoodOpen && trunkOpen {
            return "Hood & Trunk open"
        } else if hoodOpen {
            return "Hood open"
        } else if trunkOpen {
            return "Trunk open"
        } else {
            return "Closed"
        }
    }

    private var isOpen: Bool {
        hoodOpen || trunkOpen
    }

    var body: some View {
        HStack {
            carSideIcon
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text("Hood/Trunk")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(isOpen ? .orange : .green)
        }
    }

    @ViewBuilder
    private var carSideIcon: some View {
        if hoodOpen && trunkOpen {
            ZStack {
                Image(systemName: "car.side.front.open")
                Image(systemName: "car.side.rear.open")
            }
            .drawingGroup()
        } else if hoodOpen {
            Image(systemName: "car.side.front.open")
        } else if trunkOpen {
            Image(systemName: "car.side.rear.open")
        } else {
            Image(systemName: "car.side")
        }
    }
}
