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
    /// Namespace used for `matchedGeometryEffect` on the refresh button (so
    /// it smoothly morphs from its collapsed position beside the title card
    /// to its expanded position at the top-trailing of the expanded card)
    /// and `glassEffectUnion` (so the two glass pills visually merge into
    /// one shape when expanded).
    @Namespace private var glassNs

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
        PersistentModelGuard(model: bbVehicle) {
            // GlassEffectContainer is required for `glassEffectUnion` to
            // actually merge the title card's and refresh button's glass
            // shapes when expanded. Known caveat (FB22549321): Menu morph
            // animations look glitchy inside a GlassEffectContainer on
            // iOS 26.1 — the long-press context menu is rare enough that
            // we're accepting that visual trade-off for the expansion morph.
            GlassEffectContainer {
                if isExpanded {
                    expandedLayout
                } else {
                    collapsedLayout
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
        .sheet(isPresented: $showingVehicleInfo) {
            NavigationView {
                VehicleInfoView(bbVehicle: bbVehicle)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
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
                            ToolbarItem(placement: .automatic) {
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
                            ToolbarItem(placement: .automatic) {
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
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
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
                            ToolbarItem(placement: .automatic) {
                                Button("Done") { showingTripDetails = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Collapsed Layout

    @ViewBuilder
    private var collapsedLayout: some View {
        HStack(alignment: .bottom, spacing: 8) {
            collapsedTitleCard
            refreshButton
                .matchedGeometryEffect(id: "refreshButton", in: glassNs)
        }
    }

    @ViewBuilder
    private var collapsedTitleCard: some View {
        // Using Button + .contextMenu (rather than Menu + primaryAction)
        // because macCatalyst's runtime strips complex custom content
        // from Menu labels — on Mac the expanded card would end up with
        // a single-line title instead of the full VStack of status rows
        // we actually built. Button renders the label verbatim on every
        // platform; the long-press menu is attached via .contextMenu
        // and works identically (right-click on Mac, long-press on iOS).
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bbVehicle.displayName)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }

                Spacer()

                if let lastUpdated = bbVehicle.lastUpdated {
                    Text(compactLastUpdated(lastUpdated))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(height: buttonHeight, alignment: .leading)
            .vehicleCardGlassEffect()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Expanded Layout

    @ViewBuilder
    private var expandedLayout: some View {
        // ZStack so the refresh button overlays at the top-trailing of the
        // expanded card. The expanded title card reserves a `buttonHeight`-
        // sized clear slot on the right of its header row so the overlaid
        // button visually lands inside the card without colliding with text.
        ZStack(alignment: .topTrailing) {
            expandedTitleCard
            refreshButton
                .matchedGeometryEffect(id: "refreshButton", in: glassNs)
                .padding(4)
        }
    }

    @ViewBuilder
    private var expandedTitleCard: some View {
        // Same Button + .contextMenu pattern as the collapsed card — see
        // comment on `collapsedTitleCard` for why we avoid SwiftUI Menu.
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bbVehicle.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        Text(bbVehicle.vin)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Reserve space for the refresh button overlay — the
                    // button itself is rendered by `expandedLayout`'s
                    // ZStack above this view, not as a child here, so it
                    // can receive its own taps without firing the
                    // expand-toggle.
                    Color.clear
                        .frame(width: buttonHeight, height: buttonHeight)
                }
                expandedContent
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .vehicleCardGlassEffect()
            .glassEffectUnion(id: "headerGroup", namespace: glassNs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Refresh Button

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
            // Union only applied in the expanded state so the button's
            // glass merges into the same shape as the expanded title card.
            // When collapsed, we want the button to render as its own
            // separate pill.
            .modifier(
                ConditionalGlassUnion(
                    enabled: isExpanded,
                    id: "headerGroup",
                    namespace: glassNs
                )
            )
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

            // User tapped refresh: force a real-time poll so the response
            // reflects the vehicle's current state, not the backend cache.
            try await account.fetchAndUpdateVehicleStatus(
                for: bbVehicle,
                modelContext: modelContext,
                cached: false
            )

            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = true
                WidgetCenter.shared.reloadAllTimelines()

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
        // Note: no inner padding — `expandedTitleCard`'s outer VStack has
        // `.padding()` all around, so adding horizontal/bottom here would
        // double the inset.
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
        let frontLeft = doorOpen.frontLeft
        let frontRight = doorOpen.frontRight
        let backLeft = doorOpen.backLeft
        let backRight = doorOpen.backRight

        if !doorOpen.anyOpen {
            Image("custom.car.top")
        } else if frontLeft && frontRight && backLeft && backRight {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.left.and.rear.right.open")
        } else if frontLeft && frontRight && backLeft {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.left.open")
        } else if frontLeft && frontRight && backRight {
            Image(systemName: "car.top.door.front.left.and.front.right.and.rear.right.open")
        } else if frontLeft && backLeft && backRight {
            Image(systemName: "car.top.door.front.left.and.rear.left.and.rear.right.open")
        } else if frontRight && backLeft && backRight {
            Image(systemName: "car.top.door.front.right.and.rear.left.and.rear.right.open")
        } else if frontLeft && frontRight {
            Image(systemName: "car.top.door.front.left.and.front.right.open")
        } else if backLeft && backRight {
            Image(systemName: "car.top.door.rear.left.and.rear.right.open")
        } else if frontLeft && backLeft {
            Image(systemName: "car.top.door.front.left.and.rear.left.open")
        } else if frontRight && backRight {
            Image(systemName: "car.top.door.front.right.and.rear.right.open")
        } else if frontLeft && backRight {
            Image(systemName: "car.top.door.front.left.and.rear.right.open")
        } else if frontRight && backLeft {
            Image(systemName: "car.top.door.front.right.and.rear.left.open")
        } else if frontLeft {
            Image(systemName: "car.top.door.front.left.open")
        } else if frontRight {
            Image(systemName: "car.top.door.front.right.open")
        } else if backLeft {
            Image(systemName: "car.top.door.rear.left.open")
        } else if backRight {
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

        if bbVehicle.fuelType.hasElectricCapability && vehicleAccount?.supportsEVTripDetails == true {
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

// MARK: - Conditional Glass Union

/// Applies `glassEffectUnion(id:namespace:)` only when `enabled` is true.
/// Used so the refresh button's glass merges with the title card's glass
/// when the card is expanded, but stays as its own separate pill when
/// collapsed.
private struct ConditionalGlassUnion: ViewModifier {
    let enabled: Bool
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffectUnion(id: id, namespace: namespace)
        } else {
            content
        }
    }
}
