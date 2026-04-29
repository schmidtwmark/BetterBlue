//
//  MainView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 7/14/25.
//

import BetterBlueKit
import MapKit
import SwiftData
import SwiftUI
import WidgetKit

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Drives the iPad/Mac split-view vs. iPhone overlay branching at the
    /// top of `mainContent` (MAR-55). Compact width → existing overlay
    /// path, untouched.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// macCatalyst Settings window opens via `openWindow(id: "settings")`
    /// instead of a sheet. Unused on iOS, but the binding is always
    /// present — it's benign when `openWindow(id:)` points at a scene
    /// that doesn't exist on the platform (the call no-ops).
    @Environment(\.openWindow) private var openWindow
    @Query private var accounts: [BBAccount]
    @Query(
        filter: #Predicate<BBVehicle> { vehicle in !vehicle.isHidden },
        sort: \BBVehicle.sortOrder,
    ) private var displayedVehicles: [BBVehicle]

    @State private var showingSettings = false
    @State private var showingAddAccount = false
    @State private var selectedVehicleIndex = 0
    @State private var mapCameraPosition: MapCameraPosition?
    @State private var markerMenuPosition = CGPoint.zero
    @State private var isLoading = false
    @State var lastError: APIError?

    @State private var screenHeight: CGFloat = 0
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0, longitude: -100.0),
        span: MKCoordinateSpan(latitudeDelta: 50.0, longitudeDelta: 60.0),
    )

    @Namespace private var transition

    var currentVehicle: BBVehicle? {
        guard selectedVehicleIndex < displayedVehicles.count else {
            return nil
        }
        return displayedVehicles[selectedVehicleIndex]
    }

    // MARK: - Map Centering Logic

    /// Centralized map centering configuration
    private enum MapCenteringConfig {
        static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        static let animationDuration: Double = 0.8
        static let minimumSignificantChange: Double = 0.0001 // ~11 meters
    }

    /// Calculate the latitude offset needed to center the vehicle properly.
    /// On iPhone (compact width) the floating card overlay covers the bottom
    /// of the screen, so we shift the camera up by ~1/4 of the screen so
    /// the pin stays visible above the controls. On iPad / Mac (regular
    /// width) the controls float in the bottom-trailing corner with empty
    /// map space everywhere else, so we center on the vehicle directly
    /// with no offset.
    private func calculateLatitudeOffset(
        for _: CLLocationCoordinate2D,
    ) -> Double {
        if hSizeClass == .regular {
            return 0
        }
        let quarterScreenOffset = screenHeight / 4
        let latitudePerPixel = MapCenteringConfig.defaultSpan.latitudeDelta /
            screenHeight
        return quarterScreenOffset * latitudePerPixel
    }

    /// Determine the optimal center coordinate for the map
    private func calculateMapCenter(
        for vehicle: BBVehicle,
    ) -> CLLocationCoordinate2D {
        guard let vehicleCoordinate = vehicle.coordinate else {
            return CLLocationCoordinate2D()
        }

        let latitudeOffset = calculateLatitudeOffset(
            for: vehicleCoordinate,
        )
        let adjustedCenter = CLLocationCoordinate2D(
            latitude: vehicleCoordinate.latitude - latitudeOffset,
            longitude: vehicleCoordinate.longitude,
        )

        return adjustedCenter
    }

    /// Check if the current map region is significantly different from the target
    private func shouldUpdateMapRegion(
        to newCenter: CLLocationCoordinate2D,
    ) -> Bool {
        let latDiff = abs(mapRegion.center.latitude - newCenter.latitude)
        let lonDiff = abs(mapRegion.center.longitude - newCenter.longitude)
        let shouldUpdate = latDiff > MapCenteringConfig.minimumSignificantChange ||
            lonDiff > MapCenteringConfig.minimumSignificantChange

        return shouldUpdate
    }

    var body: some View {
        GeometryReader { geometry in
            mainContent
                .onAppear {
                    screenHeight = geometry.size.height
                    BBLogger.debug(.app, "MapCentering: Screen height initialized: \(Int(screenHeight))px")
                    centerOnFirstAvailableVehicle(reason: "initial view appearance")
                    Task {
                        await loadVehiclesForAllAccounts()
                    }
                }
                .onChange(of: geometry.size.height) { _, newHeight in
                    screenHeight = newHeight
                    // Recalculate centering when screen size changes (rare)
                    if currentVehicle != nil {
                        updateMapRegion(reason: "screen size changed")
                    }
                }
                .onChange(of: currentVehicle?.location) { _, _ in
                    updateMapRegion(reason: "vehicle location updated")
                }
                .onChange(of: displayedVehicles.count) { oldCount, newCount in
                    // If vehicles were removed/hidden, ensure selectedVehicleIndex is valid
                    if selectedVehicleIndex >= displayedVehicles.count,
                       !displayedVehicles.isEmpty {
                        selectedVehicleIndex = min(
                            selectedVehicleIndex,
                            displayedVehicles.count - 1,
                        )
                    }

                    // Only update map region if this is a meaningful change after startup
                    if currentVehicle != nil, oldCount > 0 {
                        // Only recenter if we're removing vehicles,
                        // not adding them during startup
                        if newCount < oldCount {
                            updateMapRegion(
                                reason: "vehicles removed, recentering (onChange)",
                            )
                        } else {
                            BBLogger.debug(.app, "MapCentering: Vehicles added, but keeping current position")
                        }
                    }
                }
                .onChange(of: selectedVehicleIndex) { _, _ in
                    Task {
                        await refreshCurrentVehicleIfNeeded(modelContext: modelContext)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .selectVehicle),
                ) { notification in
                    guard let vin = notification.object as? String else { return }
                    if let index = displayedVehicles.firstIndex(where: {
                        $0.vin == vin
                    }) {
                        selectedVehicleIndex = index
                        updateMapRegion(reason: "deep link to vehicle")
                        Task {
                            await refreshCurrentVehicleIfNeeded(modelContext: modelContext)
                        }
                    }
                }
                .task {
                    while true {
                        try? await Task.sleep(for: .seconds(60))
                        // Skip refresh when backgrounded to avoid 0xdead10cc crashes
                        // from holding SQLite file locks during suspension
                        guard scenePhase == .active else { continue }
                        await refreshCurrentVehicleIfNeeded(modelContext: modelContext)
                    }
                }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        // On regular-width displays (iPad landscape, Mac Catalyst), swap
        // the mobile overlay for a three-column split view. Compact width
        // (iPhone, iPad-split-screen narrow) stays on the existing layout
        // verbatim — no shared code with the split path so the iPhone
        // experience is guaranteed unchanged (MAR-55).
        if hSizeClass == .regular
            && !accounts.isEmpty
            && !displayedVehicles.isEmpty
            && lastError == nil {
            splitViewContent
        } else {
            compactContent
        }
    }

    // MARK: - Compact (iPhone / narrow iPad) layout — original design

    @ViewBuilder
    private var compactContent: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    // Show only the no accounts view when there are no accounts
                    EmptyAccountsView(transition: transition)
                } else if displayedVehicles.isEmpty || lastError != nil {
                    EmptyVehiclesView(
                        isLoading: $isLoading,
                        lastError: $lastError,
                    )
                } else {
                    // Show map with content overlay when accounts exist
                    ZStack {
                        SimpleMapView(
                            currentVehicle: currentVehicle,
                            mapRegion: $mapRegion,
                        )

                        VStack {
                            Spacer()
                                .allowsHitTesting(false) // Allow map touches to pass through
                            VehicleCardsView(
                                displayedVehicles: displayedVehicles,
                                accounts: accounts,
                                selectedVehicleIndex: $selectedVehicleIndex,
                                onSuccessfulRefresh: {
                                    // Clear global error when any vehicle refresh succeeds
                                    lastError = nil
                                },
                            )
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                #if os(iOS)
                SettingsView()
                    .navigationTransition(
                        .zoom(sourceID: "settings", in: transition),
                    )
                #else
                SettingsView()
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Settings", systemImage: "gearshape.fill") {
                        showingSettings = true
                    }.labelStyle(.iconOnly)
                }
                #if os(iOS)
                .matchedTransitionSource(id: "settings", in: transition)
                #endif
            }
        }
    }

    // MARK: - Regular (iPad landscape / Mac) split view layout

    @ViewBuilder
    private var splitViewContent: some View {
        NavigationSplitView {
            // Sidebar: vehicle list, sorted by `BBVehicle.sortOrder` (the
            // same `displayedVehicles` query the iPhone path uses, so the
            // ordering matches across platforms once the SwiftData store
            // syncs). No leading icon — the row is just the display name
            // and the lock-state subtitle.
            List(selection: Binding<Int?>(
                get: { selectedVehicleIndex },
                set: { newValue in
                    if let newValue { selectedVehicleIndex = newValue }
                }
            )) {
                ForEach(Array(displayedVehicles.enumerated()), id: \.element.id) { index, vehicle in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vehicle.displayName)
                            .font(.headline)
                        if let lockStatus = vehicle.lockStatus {
                            Text(lockStatus == .locked ? "Locked" : "Unlocked")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(index)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            #if os(iOS)
            // iPad: settings button lives top-right of the detail
            // pane (see the `.toolbar` on the detail column below).
            // The sidebar has no toolbar action of its own.
            #endif
        } detail: {
            // Detail: the iPhone experience, but the floating card
            // anchors to the bottom-trailing corner (typical Mac
            // floating-controls placement) with bottom padding so the
            // card doesn't hug the window chrome.
            ZStack {
                SimpleMapView(
                    currentVehicle: currentVehicle,
                    mapRegion: $mapRegion,
                )

                if let vehicle = currentVehicle {
                    VStack {
                        Spacer()
                            .allowsHitTesting(false)
                        HStack(alignment: .bottom) {
                            Spacer()
                                .allowsHitTesting(false)
                            VehicleCardView(
                                bbVehicle: vehicle,
                                bbVehicles: displayedVehicles,
                                accounts: accounts,
                                onVehicleSelected: { selected in
                                    if let index = displayedVehicles.firstIndex(where: {
                                        $0.vin == selected.vin
                                    }) {
                                        selectedVehicleIndex = index
                                    }
                                },
                                onSuccessfulRefresh: {
                                    lastError = nil
                                },
                            )
                            // Key on VIN so SwiftUI tears down and
                            // rebuilds the card when the user switches
                            // vehicles in the sidebar. Without this, the
                            // card's own `@State` properties — error
                            // banner, in-flight refresh task, MFA state
                            // — would leak from the previous selection.
                            .id(vehicle.vin)
                            .frame(maxWidth: 420)
                        }
                    }
                    .padding(.bottom, 24)
                    .padding(.trailing, 16)
                }
            }
            .ignoresSafeArea()
            #if os(iOS)
            // iPad: Settings button lives in the detail pane's
            // top-right toolbar, mirroring the iPhone gear-icon
            // position. On macOS the native `Settings` scene already
            // adds "Settings…" under the app menu (⌘,) — no in-window
            // button needed.
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Settings", systemImage: "gearshape.fill") {
                        showingSettings = true
                    }
                    .labelStyle(.iconOnly)
                }
            }
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

// MARK: - Map Centering

extension MainView {
    /// Centralized method to update map region with proper centering
    private func updateMapRegion(
        reason: String = "unknown",
    ) {
        BBLogger.debug(.app, "MapCentering: updateMapRegion called - \(reason)")

        guard let vehicle = currentVehicle else {
            BBLogger.error(.app, "MapCentering: No current vehicle selected")
            return
        }

        guard vehicle.coordinate != nil else {
            BBLogger.error(.app, "MapCentering: Vehicle \(vehicle.displayName) has no coordinate")
            return
        }

        let newCenter = calculateMapCenter(for: vehicle)

        // Only update if the change is significant
        guard shouldUpdateMapRegion(to: newCenter) else {
            return
        }

        let newRegion = MKCoordinateRegion(
            center: newCenter,
            span: MapCenteringConfig.defaultSpan,
        )

        BBLogger.debug(.app, "MapCentering: Updating map region for \(vehicle.displayName)")

        withAnimation(
            .easeInOut(duration: MapCenteringConfig.animationDuration),
        ) {
            mapRegion = newRegion
        }
    }

    /// Center map on first available vehicle
    private func centerOnFirstAvailableVehicle(
        reason: String = "initial load",
    ) {
        BBLogger.debug(.app, "MapCentering: centerOnFirstAvailableVehicle called - \(reason)")

        // Find first vehicle with location data
        if let firstVehicleWithLocation = displayedVehicles.first(where: {
            $0.coordinate != nil
        }),
            let index = displayedVehicles.firstIndex(of: firstVehicleWithLocation) {
            selectedVehicleIndex = index
            updateMapRegion(
                reason: "centering on \(firstVehicleWithLocation.displayName)",
            )
        } else {
            BBLogger.error(.app, "MapCentering: No vehicles with location data found")
        }
    }
}

// MARK: - Vehicle Loading

extension MainView {
    /// Initialize the view from SwiftData (no separate cache needed)
    private func initializeFromSwiftData() {
        BBLogger.debug(.app, "MapCentering: Available vehicles: \(displayedVehicles.count)")
        for (index, vehicle) in displayedVehicles.enumerated() {
            let hasCoord = vehicle.coordinate != nil
            BBLogger.debug(.app, "MapCentering: Vehicle \(index): \(vehicle.displayName) - has coordinate: \(hasCoord)")
        }
        if let firstVehicleWithLocation = displayedVehicles.first(where: {
            $0.coordinate != nil
        }),
            let index = displayedVehicles.firstIndex(of: firstVehicleWithLocation) {
            selectedVehicleIndex = index
            let center = calculateMapCenter(
                for: firstVehicleWithLocation,
            )
            mapRegion = MKCoordinateRegion(
                center: center,
                span: MapCenteringConfig.defaultSpan,
            )
        }
    }

    private func loadVehiclesForAllAccounts() async {
        let wasEmpty = await MainActor.run {
            isLoading = true
            lastError = nil
            return displayedVehicles.isEmpty
        }

        var hasSuccessfulAccount = false
        var latestError: APIError?

        for account in accounts {
            do {
                try await account.initialize(modelContext: modelContext)
                try await account.loadVehicles(modelContext: modelContext)
                hasSuccessfulAccount = true
            } catch {
                let user = account.username
                if let apiError = error as? APIError {
                    BBLogger.warning(.app, "MainView: Failed to load vehicles for '\(user)': \(apiError.message)")
                    latestError = apiError
                } else {
                    BBLogger.error(.app, "MainView: Failed to load vehicles for '\(user)': \(error.localizedDescription)")
                    latestError = APIError(
                        message: error.localizedDescription,
                    )
                }
            }
        }

        await MainActor.run {
            isLoading = false
            if hasSuccessfulAccount || !displayedVehicles.isEmpty {
                lastError = nil
            } else {
                lastError = latestError
            }
        }

        await MainActor.run {
            if wasEmpty {
                centerOnFirstAvailableVehicle(
                    reason: "vehicles loaded (previously empty)",
                )
            }
        }
        await loadStatusForAllVehicles()
    }

    private func loadStatusForAllVehicles() async {
        for bbVehicle in displayedVehicles {
            if let lastUpdated = bbVehicle.lastUpdated,
               lastUpdated > Date().addingTimeInterval(-300) {
                continue
            }

            do {
                if let account = bbVehicle.account {
                    let status = try await account.fetchVehicleStatus(
                        for: bbVehicle,
                        modelContext: modelContext,
                    )
                    bbVehicle.updateStatus(with: status)

                    await MainActor.run {
                        WidgetCenter.shared.reloadTimelines(
                            ofKind: "BetterBlueWidget",
                        )
                    }
                }

            } catch {
                BBLogger.warning(.app, "MainView: Failed to load status for vehicle \(bbVehicle.vin): \(error)")
            }
        }
    }

}

#Preview {
    MainView()
}
