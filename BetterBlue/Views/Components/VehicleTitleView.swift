//
//  VehicleTitleView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//
// swiftlint:disable type_body_length

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleTitleView: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    let onVehicleSelected: (BBVehicle) -> Void
    let accounts: [BBAccount]
    var transition: Namespace.ID?
    var onRefresh: (() async -> Void)?
    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared

    @State private var isExpanded = false
    @State private var isRefreshing = false
    @State private var showRefreshSuccess = false
    @State private var showingVehicleInfo = false
    @State private var showingAccountInfo = false
    @State private var showingHTTPLogs = false
    @State private var showingVehicleConfiguration = false
    @State private var showingTripDetails = false
    @State private var customVehicleName = ""
    @Namespace private var fallbackTransition

    /// Fixed height for the quick action button
    private let buttonHeight: CGFloat = 52

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
        HStack(alignment: .bottom, spacing: 8) {
            // Left side: Title card with expandable content
            titleCard

            // Right side: Refresh button (stays at bottom)
            refreshButton
        }
        .contextMenu {
            contextMenuContent
        }
        .sheet(isPresented: $showingVehicleInfo) {
            NavigationView {
                VehicleInfoView(bbVehicle: bbVehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { showingVehicleInfo = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingAccountInfo) {
            if let account = vehicleAccount {
                NavigationView {
                    AccountInfoView(account: account)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") { showingAccountInfo = false }
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
                                Button("Done") { showingHTTPLogs = false }
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
                                Button("Done") { showingVehicleConfiguration = false }
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
                            Button("Done") { showingTripDetails = false }
                        }
                    }
            }
        }
    }

    // MARK: - Title Card (Left Side)

    @ViewBuilder
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - fixed height when collapsed
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bbVehicle.displayName)
                        .font(isExpanded ? .title2 : .headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    // VIN only shown when expanded
                    if isExpanded {
                        Text(bbVehicle.vin)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Last update time shown in header when collapsed
                if !isExpanded, let lastUpdated = bbVehicle.lastUpdated {
                    Text(compactLastUpdated(lastUpdated))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding()
            .frame(height: isExpanded ? nil : buttonHeight, alignment: .leading)
            .frame(minHeight: buttonHeight)

            // Expanded content
            if isExpanded {
                expandedContent
            }
        }
        .vehicleCardGlassEffect()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Refresh Button (Right Side)

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task {
                await performRefresh()
            }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if showRefreshSuccess {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
            }
            .frame(width: buttonHeight, height: buttonHeight)
            .vehicleCardGlassEffect()
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isRefreshing)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showRefreshSuccess)
    }

    // MARK: - Refresh Logic

    private func performRefresh() async {
        await MainActor.run {
            isRefreshing = true
            showRefreshSuccess = false
        }

        do {
            guard let account = bbVehicle.account else {
                throw APIError(message: "Account not found for vehicle")
            }

            try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: modelContext)

            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = true
                WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")

                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        showRefreshSuccess = false
                    }
                }
            }

            // Call the optional refresh callback
            await onRefresh?()
        } catch {
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = false
                BBLogger.error(.app, "VehicleTitleView: Error refreshing vehicle \(bbVehicle.vin): \(error)")
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Last update time (when status was last updated)
            if let lastUpdated = bbVehicle.lastUpdated {
                StatusInfoRow(
                    icon: "arrow.clockwise",
                    label: "Last Update",
                    value: formatLastUpdated(lastUpdated)
                )
            }

            // Last sync time (when car synced to server)
            if let syncDate = bbVehicle.syncDate {
                StatusInfoRow(
                    icon: "car",
                    label: "Car Synced",
                    value: formatLastUpdated(syncDate)
                )
            }

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

            // Doors Status
            if let doorOpen = bbVehicle.doorOpen {
                let doorStatus = buildDoorStatusText(doorOpen: doorOpen)
                DoorStatusRow(
                    doorIcon: buildDoorIcon(doorOpen: doorOpen),
                    value: doorStatus.text,
                    valueColor: doorStatus.isOpen ? .orange : .green
                )
            }

            // Hood/Trunk Status
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
        .padding([.horizontal, .bottom])
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
            return ("Closed", false)
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

    @ViewBuilder
    private func buildDoorIcon(doorOpen: VehicleStatus.DoorStatus) -> some View {
        let fl = doorOpen.frontLeft
        let fr = doorOpen.frontRight
        let bl = doorOpen.backLeft
        let br = doorOpen.backRight

        if !doorOpen.anyOpen {
            Image("custom.car.top")
        } else if fl && fr && bl && br {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.left.and.rear.right.open")
        } else if fl && fr && bl {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.left.open")
        } else if fl && fr && br {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.right.open")
        } else if fl && bl && br {
            Image(systemName: "car.top.door.front.left.and.rear.left.and.rear.right.open")
        } else if fr && bl && br {
            Image(systemName: "car.top.door.front.right.and.rear.left.and.rear.right.open")
        } else if fl && fr {
            Image(systemName: "car.top.door.front.left.and.front.right.open")
        } else if bl && br {
            Image(systemName: "car.top.door.rear.left.and.rear.right.open")
        } else if fl && bl {
            Image(systemName: "car.top.door.front.left.and.rear.left.open")
        } else if fr && br {
            Image(systemName: "car.top.door.front.right.and.rear.right.open")
        } else if fl && br {
            Image(systemName: "car.top.door.front.left.and.rear.right.open")
        } else if fr && bl {
            Image(systemName: "car.top.door.front.right.and.rear.left.open")
        } else if fl {
            Image(systemName: "car.top.door.front.left.open")
        } else if fr {
            Image(systemName: "car.top.door.front.right.open")
        } else if bl {
            Image(systemName: "car.top.door.rear.left.open")
        } else if br {
            Image(systemName: "car.top.door.rear.right.open")
        } else {
            Image("custom.car.top")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if bbVehicles.count > 1 {
            Menu {
                ForEach(bbVehicles, id: \.id) { vehicle in
                    Button {
                        onVehicleSelected(vehicle)
                    } label: {
                        HStack {
                            Text(vehicle.displayName)
                            if vehicle.id == bbVehicle.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
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

// MARK: - Door Status Row

private struct DoorStatusRow<Icon: View>: View {
    let doorIcon: Icon
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            doorIcon
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text("Doors")
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
            Image("custom.car.side.rear.open.front.open")
        } else if hoodOpen {
            Image(systemName: "car.side.front.open")
        } else if trunkOpen {
            Image(systemName: "car.side.rear.open")
        } else {
            Image(systemName: "car.side")
        }
    }
}
