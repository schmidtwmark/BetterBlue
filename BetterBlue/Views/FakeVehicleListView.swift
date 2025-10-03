//
//  FakeVehicleListView.swift
//  BetterBlue
//
//  Reusable fake vehicle management component
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct FakeVehicleListView: View {
    @Binding var vehicles: [BBVehicle]
    @Environment(\.modelContext) private var modelContext

    let accountId: UUID?

    private struct VehicleConfig {
        let model: String
        let isElectric: Bool
        let batteryPercentage: Double
        let fuelPercentage: Double
        let isLocked: Bool
        let climateDefrost: Bool
        let climateAir: Bool
        let temperature: Double
        let isCharging: Bool
        let isPluggedIn: Bool
        let chargeSpeed: Double
        let odometer: Double
    }

    var body: some View {
        Section {
            if vehicles.isEmpty {
                HStack {
                    Image(systemName: "car")
                        .foregroundColor(.secondary)
                    Text("No fake vehicles")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(vehicles) { vehicle in
                    NavigationLink(destination: FakeVehicleDetailView(vehicle: vehicle)) {
                        VehicleRow(vehicle: vehicle)
                    }
                }
                .onDelete(perform: deleteVehicles)
                .onMove(perform: moveVehicles)
            }
        } header: {
            HStack {
                Text("Fake Vehicles")
                Spacer()

                Button("Add Vehicle") {
                    addNewVehicle()
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
        }
    }

    private func addNewVehicle() {
        let newVehicle = createDefaultFakeVehicle(index: vehicles.count, accountId: accountId)
        vehicles.append(newVehicle)
        modelContext.insert(newVehicle)

        // If we have an accountId, establish the SwiftData relationship
        if let accountId {
            // Find the account and add this vehicle to its relationship
            let accountFetch = FetchDescriptor<BBAccount>(predicate: #Predicate { $0.id == accountId })
            if let account = try? modelContext.fetch(accountFetch).first {
                if account.vehicles == nil {
                    account.vehicles = []
                }
                account.vehicles?.append(newVehicle)
            }
        }

        saveChanges()
    }

    private func deleteVehicles(offsets: IndexSet) {
        for index in offsets.reversed() {
            let vehicle = vehicles[index]
            modelContext.delete(vehicle)
            vehicles.remove(at: index)
        }
        saveChanges()
    }

    private func moveVehicles(from source: IndexSet, to destination: Int) {
        vehicles.move(fromOffsets: source, toOffset: destination)

        // Update sort orders
        for (index, vehicle) in vehicles.enumerated() {
            vehicle.sortOrder = index
        }
        saveChanges()
    }

    private func saveChanges() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save vehicle changes: \(error)")
        }
    }

    private func createDefaultFakeVehicle(index: Int, accountId: UUID?) -> BBVehicle {
        let configs = [
            VehicleConfig(model: "Hyundai IONIQ 5", isElectric: true, batteryPercentage: 92.0, fuelPercentage: 0.0,
                          isLocked: true, climateDefrost: true, climateAir: true, temperature: 68.0,
                          isCharging: true, isPluggedIn: true, chargeSpeed: 45.0, odometer: 8500.0),
            VehicleConfig(model: "Hyundai Sonata", isElectric: false, batteryPercentage: 0.0, fuelPercentage: 75.0,
                          isLocked: false, climateDefrost: false, climateAir: false, temperature: 70.0,
                          isCharging: false, isPluggedIn: false, chargeSpeed: 0.0, odometer: 32000.0),
            VehicleConfig(model: "Kia EV6", isElectric: true, batteryPercentage: 88.0, fuelPercentage: 0.0,
                          isLocked: false, climateDefrost: false, climateAir: true, temperature: 70.0,
                          isCharging: false, isPluggedIn: true, chargeSpeed: 0.0, odometer: 12000.0)
        ]

        let configIndex = index % configs.count
        let config = configs[configIndex]

        let vehicleId = 200 + index
        let vin = "FAKE-\(config.model)-\(vehicleId)"
        let regId = "REG\(vehicleId)"

        let odometer = Distance(length: config.odometer, units: .miles)
        let vehicle = Vehicle(
            vin: vin,
            regId: regId,
            model: config.model,
            accountId: accountId ?? UUID(),
            isElectric: config.isElectric,
            generation: 3,
            odometer: odometer,
        )

        let bbVehicle = BBVehicle(from: vehicle, backgroundColorName: index % 2 == 0 ? "darkBlue" : "darkGreen")

        configureVehicleStatus(bbVehicle, config: config, index: index)

        return bbVehicle
    }

    private func configureVehicleStatus(
        _ bbVehicle: BBVehicle,
        config: VehicleConfig,
        index: Int,
    ) {
        let location = VehicleStatus.Location(
            latitude: 37.7749 + Double.random(in: -0.01 ... 0.01),
            longitude: -122.4194 + Double.random(in: -0.01 ... 0.01),
        )

        bbVehicle.location = location
        bbVehicle.lockStatus = config.isLocked ? .locked : .unlocked
        bbVehicle.climateStatus = VehicleStatus.ClimateStatus(
            defrostOn: config.climateDefrost,
            airControlOn: config.climateAir,
            steeringWheelHeatingOn: false,
            temperature: Temperature(value: config.temperature, units: .fahrenheit),
        )

        if config.isElectric {
            let evRange = Distance(length: config.batteryPercentage * 3.0, units: .miles)
            bbVehicle.evStatus = VehicleStatus.EVStatus(
                charging: config.isCharging,
                chargeSpeed: config.chargeSpeed,
                pluggedIn: config.isPluggedIn,
                evRange: VehicleStatus.FuelRange(range: evRange, percentage: config.batteryPercentage),
            )
        } else {
            let gasRangeDistance = Distance(length: config.fuelPercentage * 4.0, units: .miles)
            bbVehicle.gasRange = VehicleStatus.FuelRange(
                range: gasRangeDistance,
                percentage: config.fuelPercentage,
            )
        }

        bbVehicle.lastUpdated = Date()
        bbVehicle.syncDate = Date()
        bbVehicle.sortOrder = index
    }
}

struct VehicleRow: View {
    let vehicle: BBVehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vehicle.model)
                .font(.headline)

            HStack {
                Text("VIN: \(vehicle.vin)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if vehicle.isElectric {
                    if let evStatus = vehicle.evStatus {
                        Label("\(Int(evStatus.evRange.percentage))%", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else {
                    if let gasRange = vehicle.gasRange {
                        Label("\(Int(gasRange.percentage))%", systemImage: "fuelpump.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var vehicles: [BBVehicle] = []

        var body: some View {
            FakeVehicleListView(vehicles: $vehicles, accountId: UUID())
                .modelContainer(for: [BBAccount.self, BBVehicle.self])
        }
    }
    return PreviewWrapper()
}
