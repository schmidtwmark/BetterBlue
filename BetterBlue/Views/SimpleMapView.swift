import BetterBlueKit
import MapKit
import SwiftUI

struct SimpleMapView: View {
    let currentVehicle: BBVehicle?
    @Binding var mapRegion: MKCoordinateRegion
    /// Height of the persistent vehicle sheet in its collapsed
    /// detent (measured from the bottom of the screen), or 0 when
    /// the sheet doesn't span the window. Applied as a bottom
    /// safe-area inset on the map so MapKit centers the camera —
    /// and therefore the vehicle marker — in the visible area
    /// *above* the card rather than behind it.
    var bottomInset: CGFloat = 0
    /// Extra safe-area insets on the trailing and bottom edges for
    /// the part of an oversized map canvas that lies outside the
    /// window (see `MapCanvas` in `MainView`). Zero when the map is
    /// sized to the window.
    var canvasSlack: (trailing: CGFloat, bottom: CGFloat) = (0, 0)
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $mapPosition, interactionModes: []) {
            if let vehicle = currentVehicle, let coordinate = vehicle.coordinate {
                Annotation(vehicle.displayName, coordinate: coordinate) {
                    VehicleMapMarker(
                        vehicle: vehicle,
                        coordinate: coordinate,
                    )
                }
            }
        }
        // Inset FIRST, then ignore the device safe area: the map
        // fills the screen edge-to-edge, and the only safe-area
        // inset MapKit sees is the card height below. MapKit fits
        // and centers the region camera inside that safe area.
        .safeAreaPadding(EdgeInsets(
            top: 0,
            leading: 0,
            bottom: bottomInset + canvasSlack.bottom,
            trailing: canvasSlack.trailing
        ))
        .ignoresSafeArea(.all)
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

    private func updateMapPosition() {
        if mapRegion.span.latitudeDelta <= 0.02 {
            // Vehicle focus (MainView's `defaultSpan` is 0.01): fixed
            // zoom, centered on the vehicle.
            mapPosition = .camera(MapCamera(
                centerCoordinate: mapRegion.center,
                distance: Self.vehicleCameraDistance
            ))
        } else {
            // Country-scale "no location" fallback: fit the region.
            mapPosition = .region(mapRegion)
        }
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

            return SimpleMapView(currentVehicle: testVehicle, mapRegion: $mapRegion)
                .modelContainer(for: [BBAccount.self, BBVehicle.self])
        }
    }
    return PreviewWrapper()
}
