import BetterBlueKit
import MapKit
import SwiftUI

/// The part of the map the vehicle sheet covers, as insets from the
/// window's edges. All zero when a marker centered in the whole window
/// is already clear of the sheet.
struct MapSheetInsets: Equatable {
    /// Height of the collapsed sheet, from the bottom of the screen:
    /// the marker goes in the area above the card.
    var bottom: CGFloat = 0
    /// The card's far edge, from the leading edge of the screen: the
    /// marker goes in the area beside the card.
    var leading: CGFloat = 0
    /// Strip on the far side kept clear along with `leading` (the
    /// window's trailing safe area).
    var trailing: CGFloat = 0
}

/// Whether the user has moved the map away from where the app put it,
/// and the way back. The map reports into it and the recenter button
/// reads it, so that neither has to redraw `MainView` to reach the
/// other.
@MainActor
@Observable
final class MapRecentering {
    /// True once the user has panned or zoomed the map off the selected
    /// vehicle (or, with no vehicle location to show, at all).
    private(set) var isOffCenter = false
    /// Counts the requests to put the map back.
    private(set) var requests = 0

    /// Sends the map back to the selected vehicle.
    func recenter() {
        isOffCenter = false
        requests += 1
    }

    fileprivate func mapMoved(offCenter: Bool) {
        if isOffCenter != offCenter { isOffCenter = offCenter }
    }
}

struct SimpleMapView: View {
    let currentVehicle: BBVehicle?
    @Binding var mapRegion: MKCoordinateRegion
    /// Where the map tells the recenter button that the user has moved
    /// it, and hears that the user wants it back.
    let recentering: MapRecentering
    /// Where the persistent vehicle sheet sits over the map. Applied as
    /// safe-area insets on the map so MapKit centers the camera — and
    /// therefore the vehicle marker — in the visible area above or
    /// beside the card rather than behind it.
    var sheetInsets = MapSheetInsets()
    /// Extra safe-area insets on the trailing and bottom edges for
    /// the part of an oversized map canvas that lies outside the
    /// window (see `MapCanvas` in `MainView`). Zero when the map is
    /// sized to the window.
    var canvasSlack: (trailing: CGFloat, bottom: CGFloat) = (0, 0)
    @State private var mapPosition: MapCameraPosition = .automatic
    /// Flies the camera back to the vehicle (see `CameraFlight`).
    @State private var pilot = CameraPilot()

    var body: some View {
        // Panning and zooming only: turned or tilted, the map would bring
        // up a compass of its own where the settings button is.
        Map(position: $mapPosition, interactionModes: [.pan, .zoom]) {
            if let vehicle = currentVehicle, let coordinate = vehicle.coordinate {
                Annotation(vehicle.displayName, coordinate: coordinate) {
                    VehicleMapMarker(
                        vehicle: vehicle,
                        coordinate: coordinate,
                    )
                }
            }
        }
        // None of the map's own controls: the scale it would show
        // during a zoom sits at the map's top corner, which here is
        // under the status bar's clock.
        .mapControls {}
        // Inset FIRST, then ignore the device safe area: the map
        // fills the screen edge-to-edge, and the only safe-area
        // insets MapKit sees are the sheet's. MapKit fits and centers
        // the region camera inside that safe area.
        .safeAreaPadding(EdgeInsets(
            top: 0,
            leading: sheetInsets.leading,
            bottom: sheetInsets.bottom + canvasSlack.bottom,
            trailing: sheetInsets.trailing + canvasSlack.trailing
        ))
        .ignoresSafeArea(.all)
        // As the map moves, not once it comes to rest: the recenter
        // button is there as soon as the user has the map off the
        // vehicle, mid-drag.
        .onMapCameraChange(frequency: .continuous) { context in
            pilot.camera = context.camera
            recentering.mapMoved(offCenter: mapPosition.positionedByUser && isAway(context))
        }
        .onChange(of: recentering.requests) { _, _ in
            flyHome()
        }
        .onDisappear {
            pilot.stop()
        }
        // Another vehicle always gets the map, wherever the user had it.
        .onChange(of: currentVehicle?.vin) { _, _ in
            recentering.mapMoved(offCenter: false)
            updateMapPosition()
        }
        .onChange(of: mapRegion.center.latitude) { _, _ in
            updateMapPosition()
        }
        .onChange(of: mapRegion.center.longitude) { _, _ in
            updateMapPosition()
        }
        .onChange(of: mapRegion.span.latitudeDelta) { _, _ in
            updateMapPosition()
        }
        .onChange(of: mapRegion.span.longitudeDelta) { _, _ in
            updateMapPosition()
        }
        .onAppear {
            updateMapPosition()
        }
    }

    /// Camera altitude used whenever the map is focused on a vehicle.
    /// A fixed distance (rather than fitting `mapRegion` into the view)
    /// keeps the zoom level independent of the visible area, so window
    /// resizes and safe-area inset changes only pan the map instead of
    /// rescaling it every step.
    private static let vehicleCameraDistance: CLLocationDistance = 6000
    /// How far the user has to have moved the map's center off the
    /// vehicle for it to count as away, as a share of the camera's
    /// distance: at the vehicle zoom, some 70 m on the ground and under
    /// 20pt on screen. A nudge smaller than that isn't worth a button.
    private static let awayOffset = 0.012
    /// And how far zoomed in or out, as a ratio of the vehicle zoom.
    private static let awayZoom = 1.2

    /// True while the map is focused on a vehicle rather than showing
    /// the country-scale "no location" fallback (MainView's
    /// `defaultSpan` is 0.01).
    private var focusesVehicle: Bool {
        mapRegion.span.latitudeDelta <= 0.02
    }

    /// Where the app puts the map: on the vehicle at a fixed zoom, or
    /// fitted to the fallback region.
    private var homePosition: MapCameraPosition {
        if focusesVehicle {
            .camera(MapCamera(
                centerCoordinate: mapRegion.center,
                distance: Self.vehicleCameraDistance
            ))
        } else {
            .region(mapRegion)
        }
    }

    /// Follows `mapRegion`, unless the user has the map somewhere else:
    /// a status refresh that moves the vehicle a little shouldn't take
    /// the map out from under them. (The marker still moves.)
    private func updateMapPosition() {
        guard !recentering.isOffCenter else { return }
        // Home has moved: a flight on its way to the old one is over.
        pilot.stop()
        mapPosition = homePosition
    }

    /// Takes the map back to where the app would have it, from wherever
    /// the user left it.
    private func flyHome() {
        guard focusesVehicle, let camera = pilot.camera else {
            // The fallback region is fitted to the view rather than
            // being a camera: there is no path to fly, so MapKit
            // animates it.
            pilot.stop()
            withAnimation(.easeInOut(duration: 0.5)) {
                mapPosition = homePosition
            }
            return
        }
        let flight = CameraFlight(
            from: camera,
            to: mapRegion.center,
            distance: Self.vehicleCameraDistance
        )
        // The map is the app's again from here, where it stands (which
        // also stops it coasting on from a swipe). Should the user move
        // it mid-flight, the position turns back into theirs, and the
        // flight leaves it with them.
        mapPosition = .camera(camera)
        pilot.fly(for: flight.duration) { elapsed in
            guard !mapPosition.positionedByUser else { return false }
            mapPosition = elapsed < 1 ? .camera(flight.camera(at: elapsed)) : homePosition
            return true
        }
    }

    /// Whether a camera the user left the map at is off where the app
    /// would have it.
    private func isAway(_ context: MapCameraUpdateContext) -> Bool {
        // The fallback region is fitted to the view, so there is no
        // camera to compare against: anywhere the user put it is away.
        guard focusesVehicle else { return true }
        let camera = context.camera
        let center = CLLocation(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude
        )
        let home = CLLocation(latitude: mapRegion.center.latitude, longitude: mapRegion.center.longitude)
        let zoom = camera.distance / Self.vehicleCameraDistance
        return center.distance(from: home) > Self.awayOffset * camera.distance
            || zoom > Self.awayZoom
            || zoom < 1 / Self.awayZoom
    }
}

/// The camera's way back to the vehicle from wherever the user left
/// the map.
///
/// MapKit's own animation between two cameras changes the altitude
/// evenly in meters, and takes two seconds over it whatever duration
/// it is asked for. From far out that is a second in which nothing
/// seems to happen — the first half of the meters is less than one
/// zoom level — and then the rest of the zoom all at once. This path
/// moves evenly in zoom levels instead, is quick off the mark, and
/// eases into the vehicle.
private struct CameraFlight {
    let duration: TimeInterval

    private let home: CLLocationCoordinate2D
    private let startDistance: CLLocationDistance
    /// Where the flight starts, as an offset from the vehicle.
    private let latitude: CLLocationDegrees
    private let longitude: CLLocationDegrees
    /// Natural logarithms of how many times farther from the ground the
    /// camera ends than it starts, and of how many times farther than
    /// either it gets at the top of its arc.
    private let zoom: Double
    private let rise: Double

    /// Shortest flight, for a map that is only a little off.
    private static let baseDuration: TimeInterval = 0.35
    /// Added for every zoom level (a doubling or halving of the
    /// camera's distance) on the way.
    private static let durationPerLevel: TimeInterval = 0.06
    private static let longestDuration: TimeInterval = 0.95
    /// Progress along the flight against time: moving at once, most of
    /// the way in the first third, and a long ease into the vehicle.
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.25, y: 0.1),
        endControlPoint: UnitPoint(x: 0.25, y: 1)
    )
    /// A pan longer than this, as a multiple of the camera's distance
    /// (which is some four times the width of a phone's map, so this
    /// is two widths), rises on the way until it is no longer: a map
    /// left zoomed in on another city flies back in an arc rather than
    /// streaking across the country at street level.
    private static let longestLevelPan = 0.5

    init(from start: MapCamera, to home: CLLocationCoordinate2D, distance: CLLocationDistance) {
        self.home = home
        startDistance = start.distance.isFinite && start.distance > 0 ? start.distance : distance
        latitude = start.centerCoordinate.latitude - home.latitude
        // The short way round the globe.
        longitude = Self.wrapped(start.centerCoordinate.longitude - home.longitude)

        let ground = CLLocation(
            latitude: start.centerCoordinate.latitude,
            longitude: start.centerCoordinate.longitude
        ).distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
        zoom = log(distance / startDistance)
        rise = max(0, log(ground / Self.longestLevelPan / max(startDistance, distance)))
        let levels = (abs(zoom) + 2 * rise) / log(2)
        duration = min(Self.longestDuration, Self.baseDuration + Self.durationPerLevel * levels)
    }

    /// The camera once `elapsed` of the flight's time has gone, from 0
    /// to 1.
    func camera(at elapsed: Double) -> MapCamera {
        let progress = Self.curve.value(at: min(1, max(0, elapsed)))
        let arc = sin(.pi * progress)
        let distance = startDistance * exp(zoom * progress + rise * arc * arc)
        // What is left of the pan shrinks with the camera's distance on
        // the way down: the vehicle then glides to the middle of the
        // screen as the map zooms in on it, where a pan paced in
        // meters would first throw it off the edge.
        let left = (1 - progress) * min(1, distance / startDistance)
        return MapCamera(
            centerCoordinate: CLLocationCoordinate2D(
                latitude: home.latitude + latitude * left,
                longitude: Self.wrapped(home.longitude + longitude * left)
            ),
            distance: distance
        )
    }

    /// A longitude, or a difference between two, brought back within
    /// half a turn of zero.
    private static func wrapped(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
        if longitude > 180 { return longitude - 360 }
        if longitude < -180 { return longitude + 360 }
        return longitude
    }
}

/// Runs a `CameraFlight`: calls back every frame with how much of the
/// flight's time has gone. Also keeps the camera the map last reported,
/// which is where a flight sets out from.
///
/// MapKit has an animator for this (`mapCameraKeyframeAnimator`), and
/// on iOS 27.0 it flies these paths well. In the iOS 27.1 simulator it
/// takes over the map's position and then never moves the camera,
/// which leaves the map where it was with the app believing it is on
/// the vehicle. So the frames are set from here instead.
@MainActor
private final class CameraPilot: NSObject {
    /// The map's camera as of its last move.
    var camera: MapCamera?

    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var step: (Double) -> Bool = { _ in false }

    /// Calls `step` every frame for `duration` seconds with the share
    /// of that time gone so far, the last call with 1. A `step` that
    /// returns false ends the flight there.
    func fly(for duration: TimeInterval, step: @escaping (Double) -> Bool) {
        stop()
        guard duration.isFinite, duration > 0 else {
            _ = step(1)
            return
        }
        self.duration = duration
        self.step = step
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        step = { _ in false }
    }

    @objc private func frame(_ link: CADisplayLink) {
        // The time this frame will be on screen.
        let elapsed = min(1, (link.targetTimestamp - start) / duration)
        let step = self.step
        if elapsed >= 1 { stop() }
        if !step(elapsed) { stop() }
    }
}

struct VehicleMapMarker: View {
    let vehicle: BBVehicle
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Menu {
            NavigationMenuContent(
                coordinate: coordinate,
                destinationName: vehicle.displayName,
            )
        } label: {
            Circle()
                .fill(vehicle.primaryColor)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 3),
                )
                .overlay(
                    Image(systemName: "car.fill")
                        .foregroundColor(.white)
                        .font(.title2),
                )
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .padding(4)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var mapRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )

        var body: some View {
            let testAccount = BBAccount(
                username: "test@example.com",
                password: "password",
                refreshToken: "",
                pin: "1234",
                brand: .hyundai,
                region: .usa
            )

            let testVehicle = BBVehicle(from: Vehicle(
                vin: "KMHL14JA5KA123456",
                regId: "REG123",
                model: "Ioniq 5",
                accountId: testAccount.id,
                fuelType: .electric,
                generation: 3,
                odometer: Distance(length: 25000, units: .miles)
            ))

            _ = {
                testVehicle.location = VehicleStatus.Location(latitude: 37.7749, longitude: -122.4194)
            }()

            return SimpleMapView(
                currentVehicle: testVehicle,
                mapRegion: $mapRegion,
                recentering: MapRecentering()
            )
                .modelContainer(for: [BBAccount.self, BBVehicle.self])
        }
    }
    return PreviewWrapper()
}
