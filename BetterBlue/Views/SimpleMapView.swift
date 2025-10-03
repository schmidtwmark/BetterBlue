import BetterBlueKit
import MapKit
import SwiftUI

struct SimpleMapView: View {
    let currentVehicle: BBVehicle?
    @Binding var mapRegion: MKCoordinateRegion
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

    private func updateMapPosition() {
        mapPosition = .region(mapRegion)
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
                .fill(Color.blue)
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
                pin: "1234",
                brand: .hyundai,
                region: .usa
            )

            let testVehicle = BBVehicle(from: Vehicle(
                vin: "KMHL14JA5KA123456",
                regId: "REG123",
                model: "Ioniq 5",
                accountId: testAccount.id,
                isElectric: true,
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
