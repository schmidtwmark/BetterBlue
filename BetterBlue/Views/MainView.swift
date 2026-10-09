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
    @Query private var accounts: [BBAccount]
    @Query(
        filter: #Predicate<BBVehicle> { vehicle in !vehicle.isHidden },
        sort: \BBVehicle.sortOrder,
    ) private var displayedVehicles: [BBVehicle]

    @State private var showingSettings = false
    /// Hoisted from `EmptyAccountsView` so the "Add Account" sheet
    /// survives brief scenePhase flips (Password autofill, screenshot
    /// capture, etc.) that unmount the empty-state view via the
    /// 0xdead10cc guard below (issue #59).
    @State private var showingAddAccount = false
    /// Same hoisting reason as `showingAddAccount`.
    @State private var showingTroubleshooting = false
    /// Tag printed on first init + on key events so we can tell if
    /// MainView itself is being reinstantiated (which would reset
    /// `@State`). Random per-instance, stable for the lifetime of
    /// the struct.
    private let instanceTag = String(UUID().uuidString.prefix(6))

    @State private var selectedVehicleIndex = 0
    /// Owned here (not in `PersistentVehicleSheet`) so the MFA verify
    /// sheet survives the `scenePhase != .active` view-tree swap in
    /// `stateContent` below. If this lived on the per-vehicle sheet,
    /// backgrounding the app during MFA would tear the sheet down
    /// and the user would be stuck in a re-auth loop on return.
    @State private var mfaState = MFAFlowState()
    /// Same hoisting rationale as `mfaState` — owns the presentation
    /// state for every per-vehicle informational sheet (vehicle info,
    /// account info, HTTP logs, climate/charge settings, error
    /// details, etc.). All 8 are driven by `presentation.active` and
    /// rendered by a single `.sheet(item:)` on `mainContent`.
    @State private var sheetPresentation = VehicleSheetPresentation()
    @State private var mapCameraPosition: MapCameraPosition?
    @State private var markerMenuPosition = CGPoint.zero
    @State private var isLoading = false
    @State var lastError: APIError?

    /// Bottom inset the map keeps clear of the vehicle sheet,
    /// reported by `VehicleSheetPager`: the selected vehicle's
    /// collapsed card height while the card spans the window, 0
    /// once the window is wide enough that the card sits beside
    /// open map. Fed to `SimpleMapView` as a safe-area inset so the
    /// marker is centered in whatever map area is unobstructed.
    @State private var mapBottomInset: CGFloat = 0
    /// True while an expanded vehicle sheet stands over the settings
    /// button, reported by `VehicleSheetPager`. The button fades out
    /// for as long as it is (see `SettingsButton`).
    @State private var sheetCoversToolbar = false
    /// Whether a vehicle sheet can rise over the toolbar's trailing item
    /// at all in this window, reported by `VehicleSheetPager` — the
    /// common case, an iPhone in portrait, until it says otherwise.
    @State private var sheetCanCoverToolbar = true
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0, longitude: -100.0),
        span: MKCoordinateSpan(latitudeDelta: 50.0, longitudeDelta: 60.0),
    )
    /// Country-level region for the device's locale, geocoded once and
    /// cached — the map falls back to this when the selected vehicle has
    /// no usable location (no GPS fix / null island).
    @State private var localeFallbackRegion: MKCoordinateRegion?
    /// Guards against kicking off a second geocode while one is running.
    @State private var isGeocodingLocaleRegion = false

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

    /// Determine the map center for a vehicle. This is simply the
    /// vehicle's own coordinate: the vertical offset that keeps the
    /// marker clear of the sheet is handled by the map's bottom
    /// safe-area inset (`mapBottomInset`) rather than by
    /// shifting the region's center — a pixel-to-degree conversion
    /// that only held for one screen aspect ratio.
    private func calculateMapCenter(
        for vehicle: BBVehicle,
    ) -> CLLocationCoordinate2D {
        vehicle.coordinate ?? CLLocationCoordinate2D()
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
        mainContent
            .onChange(of: scenePhase) { old, new in
                BBLogger.info(.app, "[SVI-\(instanceTag)] scenePhase \(old) → \(new) (idx=\(selectedVehicleIndex), count=\(displayedVehicles.count))")
                if new == .background {
                    finishStoreWorkBeforeSuspension()
                }
            }
            .onAppear {
                BBLogger.info(.app, "[SVI-\(instanceTag)] MainView .onAppear (idx=\(selectedVehicleIndex), count=\(displayedVehicles.count))")
                applyMinimumWindowSize()
                // Center the map on the current vehicle. Pure
                // map operation — does NOT touch
                // `selectedVehicleIndex` (that was the bug
                // `centerOnFirstAvailableVehicle` introduced on
                // every return-from-background). On cold launch
                // with cached SwiftData, currentVehicle is
                // already populated here, so the map renders
                // zoomed in on the right vehicle from the start
                // instead of showing a continent-scale view
                // until the user swipes. updateMapRegion falls
                // back to the locale-region view when the vehicle
                // has no usable coordinate.
                if currentVehicle != nil {
                    updateMapRegion(reason: "initial view appearance")
                }
                Task {
                    await loadVehiclesForAllAccounts()
                }
            }
            .onChange(of: currentVehicle?.location, initial: true) { _, _ in
                // `initial: true` catches the cold-launch case
                // where displayedVehicles populates asynchronously
                // — the .onAppear above runs before
                // currentVehicle is valid, so we'd otherwise be
                // stuck on the continent-scale default region
                // until the user swiped. Runs for nil/(0,0)
                // locations too: updateMapRegion then applies the
                // missing-location fallback region instead.
                if currentVehicle != nil {
                    updateMapRegion(reason: "vehicle location updated")
                }
            }
            .onChange(of: displayedVehicles.count) { oldCount, newCount in
                BBLogger.info(.app, "[SVI] count: \(oldCount) → \(newCount), idx=\(selectedVehicleIndex)")
                // If vehicles were removed/hidden, ensure selectedVehicleIndex is valid
                if selectedVehicleIndex >= displayedVehicles.count,
                   !displayedVehicles.isEmpty {
                    let clamped = min(selectedVehicleIndex, displayedVehicles.count - 1)
                    BBLogger.info(.app, "[SVI] clamping \(selectedVehicleIndex) → \(clamped) (count=\(displayedVehicles.count))")
                    selectedVehicleIndex = clamped
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
            .onChange(of: selectedVehicleIndex) { old, new in
                BBLogger.info(.app, "[SVI] CHANGED \(old) → \(new) (vin=\(currentVehicle?.vin ?? "nil"))")
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
                    BBLogger.info(.app, "[SVI] selectVehicle notification → \(index) (vin=\(vin))")
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

    /// Leaving the app: save now rather than let autosave fire after the
    /// app is suspended, and stay awake while CloudKit exports the save
    /// (and finishes anything else under way) — a write to the App Group
    /// store still in progress at suspension gets the app killed
    /// (0xdead10cc).
    private func finishStoreWorkBeforeSuspension() {
        let backgroundTask = BackgroundTask(name: "BetterBlue.enterBackground")
        try? modelContext.save()
        Task {
            await CloudKitSyncMonitor.shared.waitUntilIdle(deadline: .now + .seconds(20))
            backgroundTask.end()
        }
    }

    /// True when there are vehicles to show: the map fills the
    /// navigation stack and the vehicle sheet rides on top of it.
    private var showsVehicles: Bool {
        !accounts.isEmpty && !displayedVehicles.isEmpty && lastError == nil
    }

    /// The map under the vehicle sheet (the sheet itself is layered
    /// on in `mainContent`).
    @ViewBuilder
    private var vehicleMap: some View {
        mapLayer
            .overlay(alignment: .top) {
                // Explains the marker-less, zoomed-out map when the API
                // returned no GPS fix for the selected vehicle.
                if let vehicle = currentVehicle, vehicle.coordinate == nil {
                    missingLocationBanner(for: vehicle)
                }
            }
    }

    /// The map, sized so that interactive window resizes never change
    /// MapKit's drawable size. On iPad (windowing, split view, Stage
    /// Manager) MapKit takes on the order of seconds to re-render a
    /// resized view in the simulator, during which the system shows a
    /// stretched snapshot of the whole app — the sheet appeared to
    /// wobble and lag the window edge. Rendering into a fixed canvas
    /// the size of the screen's larger dimension, anchored top-leading,
    /// means a resize only reveals more or less of an already-rendered
    /// map. Safe-area insets tell MapKit where the window's visible
    /// region is (the canvas overhang plus the sheet), so the camera
    /// still centers the marker in the visible area. iPhone windows
    /// don't resize interactively, so they keep the live-sized map.
    @ViewBuilder
    private var mapLayer: some View {
        if let canvas = MapCanvas.size {
            GeometryReader { geo in
                Color.clear
                    .background(alignment: .topLeading) {
                        SimpleMapView(
                            currentVehicle: currentVehicle,
                            mapRegion: $mapRegion,
                            bottomInset: mapBottomInset,
                            canvasSlack: (
                                trailing: max(0, canvas.width - geo.size.width),
                                bottom: max(0, canvas.height - geo.size.height)
                            )
                        )
                        .frame(width: canvas.width, height: canvas.height)
                    }
            }
            .ignoresSafeArea()
        } else {
            SimpleMapView(
                currentVehicle: currentVehicle,
                mapRegion: $mapRegion,
                bottomInset: mapBottomInset,
            )
        }
    }

    /// Glass chip pinned to the top of the map when the selected
    /// vehicle has no usable location.
    @ViewBuilder
    private func missingLocationBanner(for vehicle: BBVehicle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.orange)
            Text("No location received from \(vehicle.displayName)")
                .font(.footnote)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Color.clear.glassEffect(.regular, in: Capsule())
        }
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: vehicle.coordinate == nil)
    }

    /// How far in from the side of the window the navigation bar keeps
    /// its items.
    private static let navigationBarMargin: CGFloat = 16

    /// Whether the settings button floats over the navigation stack
    /// (`SettingsButton`) rather than sitting in its toolbar: only where
    /// a vehicle sheet can rise over the toolbar's trailing item, which
    /// is what the floating button gets out of the way of. Everywhere
    /// else — beside a sheet that's a column in a wide window, in iPhone
    /// Duo's side toolbar, with no vehicles to show — the toolbar places
    /// the button itself.
    private var settingsButtonFloats: Bool {
        showsVehicles && sheetCanCoverToolbar
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            navigationContent
            // Where the navigation bar would put its trailing item — see
            // `SettingsButton` for why it isn't one here.
            if settingsButtonFloats {
                SettingsButton(isCovered: $sheetCoversToolbar) {
                    showingSettings = true
                }
                .matchedTransitionSource(id: "settings", in: transition)
                .padding(.trailing, Self.navigationBarMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            // Apple-Maps-style layout: map under, paged sheet on top.
            // `VehicleSheetPager` owns the horizontal ScrollView that
            // pages between vehicles, plus each card's chrome (glass +
            // drag handle). It sits ABOVE the navigation stack and the
            // settings button so an expanded card can rise through the
            // toolbar row to the status bar, the way a system sheet
            // would (the settings button fades out of its way —
            // `sheetCoversToolbar`); collapsed, everything above the
            // card (settings button, map marker) stays tappable.
            if showsVehicles {
                VehicleSheetPager(
                    bbVehicles: displayedVehicles,
                    selectedVehicleIndex: $selectedVehicleIndex,
                    onSuccessfulRefresh: { lastError = nil },
                    mfaState: mfaState,
                    sheetPresentation: sheetPresentation,
                    mapBottomInset: $mapBottomInset,
                    coversToolbar: $sheetCoversToolbar,
                    canCoverToolbar: $sheetCanCoverToolbar
                )
            }
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        NavigationStack {
            stateContent
                .toolbar {
                    if !settingsButtonFloats {
                        // Real toolbar button — system-sized hit target
                        // (44pt) in the navigation bar's trailing slot.
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .foregroundStyle(.primary)
                            }
                            .matchedTransitionSource(id: "settings", in: transition)
                        }
                    }
                }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .navigationTransition(
                        .zoom(sourceID: "settings", in: transition),
                    )
            }
            // Add Account + Troubleshooting sheets used to live on
            // EmptyAccountsView, but its view-tree gets unmounted by
            // the scenePhase guard above on brief background flips
            // (Password autofill, screenshot capture — issue #59).
            // Owning the state + .sheet here keeps them open across
            // those transitions.
            .sheet(isPresented: $showingAddAccount) {
                NavigationView {
                    AddAccountView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") { showingAddAccount = false }
                            }
                        }
                }
                .navigationTransition(
                    .zoom(sourceID: "add-account", in: transition),
                )
            }
            .sheet(isPresented: $showingTroubleshooting) {
                NavigationStack {
                    TroubleshootingView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { showingTroubleshooting = false }
                            }
                        }
                }
            }
            // MFA verify sheet attached at this layer (alongside the
            // other hoisted sheets) so it stays presented across the
            // scenePhase view-tree swap. Triggered from individual
            // `PersistentVehicleSheet`s when the user taps a
            // `.requiresMFA` error banner — they share the same
            // `mfaState` instance owned by MainView.
            .mfaFlow(state: mfaState)
            // Single dispatcher for every per-vehicle sheet. Same
            // hoisting reason as `.mfaFlow` above. Bindable wrapping
            // gives us the `Binding<Sheet?>` that `.sheet(item:)`
            // requires from an @Observable.
            .sheet(item: Bindable(sheetPresentation).active) { sheet in
                vehicleSheetContent(for: sheet)
            }
        }
    }

    /// Resolves a `VehicleSheetPresentation.Sheet` case into its
    /// actual view. Lives here (not in `PersistentVehicleSheet`)
    /// because the `.sheet(item:)` modifier is hosted at MainView.
    @ViewBuilder
    private func vehicleSheetContent(for sheet: VehicleSheetPresentation.Sheet) -> some View {
        switch sheet {
        case .errorDetails(let error, let onClear):
            ErrorDetailsSheet(
                error: error,
                onDismiss: { sheetPresentation.dismiss() },
                onClearError: {
                    onClear()
                    sheetPresentation.dismiss()
                }
            )
            .presentationDetents([.medium, .large])
        case .vehicleInfo(let vehicle):
            NavigationView {
                VehicleInfoView(bbVehicle: vehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .accountInfo(let account):
            NavigationView {
                AccountInfoView(account: account)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .httpLogs(let account):
            NavigationView {
                HTTPLogView(accountId: account.id, transition: nil)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .vehicleConfiguration(let vehicle):
            NavigationView {
                FakeVehicleDetailView(vehicle: vehicle)
                    .navigationTitle("Configure Vehicle")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .tripDetails(let vehicle):
            NavigationView {
                TripDetailsView(bbVehicle: vehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .surroundView(let vehicle):
            NavigationView {
                SurroundViewMonitorView(bbVehicle: vehicle)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { sheetPresentation.dismiss() }
                        }
                    }
            }
        case .climateSettings(let vehicle):
            ClimateSettingsSheet(vehicle: vehicle)
        case .chargeLimitSettings(let vehicle):
            ChargeLimitSettingsSheet(vehicle: vehicle)
        }
    }

    /// State-dispatched body content (empty / loading / populated).
    /// Factored out of `mainContent` so it can sit inside a
    /// `GlassEffectContainer` with the floating settings button.
    @ViewBuilder
    private var stateContent: some View {
        Group {
            // Note: previously branched on `scenePhase != .active`
            // and rendered `Color.clear` to dodge `@Query` reads
            // during background → 0xdead10cc kill. That guard
            // hasn't actually prevented the crashes (they keep
            // showing up in TestFlight reports) and the
            // unmount-on-background was breaking sheet survival,
            // scroll-position restoration, and generally making
            // the app feel clunky. Removed.
            if accounts.isEmpty {
                    EmptyAccountsView(
                        transition: transition,
                        showingAddAccount: $showingAddAccount,
                        showingTroubleshooting: $showingTroubleshooting
                    )
                } else if displayedVehicles.isEmpty || lastError != nil {
                    EmptyVehiclesView(
                        isLoading: $isLoading,
                        lastError: $lastError,
                        onRetry: { await loadVehiclesForAllAccounts() },
                    )
                } else {
                    // Same condition as `showsVehicles`, which layers
                    // the vehicle sheet over this map.
                    vehicleMap
                }
        }
    }
}

/// The settings button where a vehicle sheet can rise over the toolbar's
/// trailing item (`MainView.settingsButtonFloats` — an iPhone in
/// portrait): a 44pt glass circle around the gear, drawn the way the
/// navigation bar draws a trailing item, but floating over the
/// navigation stack (and under the vehicle sheet) instead of living in
/// its toolbar. While an expanded sheet stands over it, it fades out and
/// stops taking taps — the sheet's rounded corner would otherwise leave
/// a slice of it showing, out of reach behind the sheet.
///
/// A toolbar item can't step aside like that. The bar draws an item's
/// glass itself, and the glass stays put when the item's content fades
/// or shrinks — its top shows above the expanded sheet. Without that
/// glass, the map draws its scroll edge effect behind the bar for the
/// item's legibility: a blurred band across the top of the screen.
/// Removing and re-adding the item as the sheet went up and down has
/// left it on screen, dead. And hiding the whole bar slides it away and
/// re-lays out everything under it, stalling the sheet mid-spring.
private struct SettingsButton: View {
    /// True while an expanded vehicle sheet stands over the button. A
    /// binding so that only this button reads it: flipping it mid-
    /// animation then re-renders the button alone, not all of
    /// `MainView` (which costs a frame).
    @Binding var isCovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                // The size the navigation bar gives a symbol.
                .imageScale(.large)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                // The whole circle takes taps, not just the symbol.
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .opacity(isCovered ? 0 : 1)
        .allowsHitTesting(!isCovered)
    }
}

// MARK: - Window sizing

extension MainView {
    /// Smallest window iPadOS / Mac may resize us to. Tall enough
    /// that the collapsed card plus a strip of map stay usable; the
    /// card's content scrolls in place (see
    /// `VehicleSheetPager.cardLayout(for:geo:)`) if the window is
    /// still too short for it. No-op on iPhone, where scenes aren't
    /// resizable (`sizeRestrictions` is nil).
    private static let minimumWindowSize = CGSize(width: 375, height: 480)

    private func applyMinimumWindowSize() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = Self.minimumWindowSize
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
            applyMissingLocationFallback()
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

    /// Zoomed-out fallback when the selected vehicle has no usable
    /// location: show the user's own region (the device locale's
    /// country, geocoded once — no location permission required)
    /// instead of the hardcoded North-America default or null island.
    /// The "no location received" banner over the map explains why.
    private func applyMissingLocationFallback() {
        if let cached = localeFallbackRegion {
            if shouldUpdateMapRegion(to: cached.center) {
                withAnimation(.easeInOut(duration: MapCenteringConfig.animationDuration)) {
                    mapRegion = cached
                }
            }
            return
        }
        guard !isGeocodingLocaleRegion,
              let regionCode = Locale.current.region?.identifier,
              let countryName = Locale.current.localizedString(forRegionCode: regionCode) else {
            return
        }
        isGeocodingLocaleRegion = true
        Task { @MainActor in
            defer { isGeocodingLocaleRegion = false }
            // MKLocalSearch instead of CLGeocoder (deprecated in iOS 26);
            // its response's boundingRegion already frames the match, so
            // no radius-to-degrees math is needed.
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = countryName
            guard let response = try? await MKLocalSearch(request: request).start() else {
                BBLogger.warning(.app, "MapCentering: locale-region search failed for \(countryName)")
                return
            }
            var region = response.boundingRegion
            // Clamp to country-scale zoom: a stray point match shouldn't
            // zoom to street level, a huge match shouldn't show the globe.
            let degrees = min(40.0, max(3.0, region.span.latitudeDelta))
            region.span = MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
            localeFallbackRegion = region
            // Only apply if the vehicle still has no coordinate — a status
            // refresh may have delivered a real location mid-geocode.
            if currentVehicle != nil, currentVehicle?.coordinate == nil {
                withAnimation(.easeInOut(duration: MapCenteringConfig.animationDuration)) {
                    mapRegion = region
                }
            }
        }
    }

    /// Center map on first available vehicle. ALSO reassigns
    /// `selectedVehicleIndex` only when there isn't already a valid
    /// selection — otherwise this function ran on `.onAppear` and
    /// every return-from-background, snapping the user back to
    /// vehicle 0 (or the first one with a location) regardless of
    /// what they were actually viewing.
    private func centerOnFirstAvailableVehicle(
        reason: String = "initial load",
    ) {
        BBLogger.debug(.app, "MapCentering: centerOnFirstAvailableVehicle called - \(reason)")

        // If the current selection already has a location, just
        // re-center the map on it. Don't touch selectedVehicleIndex.
        if currentVehicle?.coordinate != nil {
            updateMapRegion(reason: "re-centering on current vehicle (\(reason))")
            return
        }

        // Otherwise (no current selection, or it has no location)
        // pick the first vehicle that does have one.
        if let firstVehicleWithLocation = displayedVehicles.first(where: {
            $0.coordinate != nil
        }),
            let index = displayedVehicles.firstIndex(of: firstVehicleWithLocation) {
            BBLogger.info(.app, "[SVI] centerOnFirstAvailableVehicle setting \(selectedVehicleIndex) → \(index) (reason=\(reason))")
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
            BBLogger.info(.app, "[SVI] initializeFromSwiftData setting \(selectedVehicleIndex) → \(index)")
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
                    // Save before reloading widget timelines so the
                    // widget process sees the fresh `lastUpdated` and
                    // doesn't re-fire its own HTTP fetch. See the
                    // detailed note in MainViewRefresh.refreshStatus.
                    try? modelContext.save()

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


/// Fixed render canvas for the map on resizable-window platforms.
/// `nil` on iPhone, where the map should simply fill the window.
@MainActor
enum MapCanvas {
    static let size: CGSize? = {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return nil }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
        let bounds = screen?.bounds.size ?? CGSize(width: 1400, height: 1400)
        // Square on the larger dimension so rotation never needs a
        // bigger canvas either.
        let side = max(bounds.width, bounds.height)
        return CGSize(width: side, height: side)
    }()
}
