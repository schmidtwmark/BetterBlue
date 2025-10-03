//
//  FakeVehicleSetupView.swift
//  BetterBlue
//
//  SwiftData-based fake vehicle configuration
//

import BetterBlueKit
import SwiftData
import SwiftUI

enum VehicleType: String, CaseIterable {
    case gas = "Gas Only"
    case electric = "Electric Only"
    case pluginHybrid = "Plug-in Hybrid"
}

struct FakeVehicleDetailView: View {
    @Bindable var vehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @State private var modelName: String = ""
    @State private var vehicleType: VehicleType = .gas
    @State private var batteryPercentage: Double = 80
    @State private var fuelPercentage: Double = 75
    @State private var odometer: Double = 25000
    @State private var isLocked: Bool = false
    @State private var climateOn: Bool = false
    @State private var temperature: Double = 70
    @State private var isCharging: Bool = false
    @State private var chargeSpeed: Double = 0
    @State private var isPluggedIn: Bool = true
    @State private var latitude: Double = 37.7749
    @State private var longitude: Double = -122.4194

    private var hasElectric: Bool {
        vehicleType == .electric || vehicleType == .pluginHybrid
    }

    private var hasGas: Bool {
        vehicleType == .gas || vehicleType == .pluginHybrid
    }

    var body: some View {
        Form {
            Section {
                TextField("Model Name", text: $modelName)
                    .onChange(of: modelName) { _, newValue in
                        vehicle.model = newValue
                        saveChanges()
                    }

                Picker("Vehicle Type", selection: $vehicleType) {
                    ForEach(VehicleType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .onChange(of: vehicleType) { _, _ in
                    updateVehicleType()
                }
            } header: {
                Text("Basic Information")
            }

            Section {
                if hasElectric {
                    HStack {
                        Text("Battery Level")
                        Spacer()
                        Text("\(Int(batteryPercentage))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $batteryPercentage, in: 0 ... 100, step: 1)
                        .onChange(of: batteryPercentage) { _, _ in updateEVStatus() }

                    Toggle("Charging", isOn: $isCharging)
                        .onChange(of: isCharging) { _, _ in updateEVStatus() }

                    Toggle("Plugged In", isOn: $isPluggedIn)
                        .onChange(of: isPluggedIn) { _, _ in updateEVStatus() }

                    if isCharging {
                        HStack {
                            Text("Charge Speed")
                            Spacer()
                            Text("\(Int(chargeSpeed)) kW")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $chargeSpeed, in: 0 ... 250, step: 1)
                            .onChange(of: chargeSpeed) { _, _ in updateEVStatus() }
                    }
                }

                if hasGas {
                    HStack {
                        Text("Fuel Level")
                        Spacer()
                        Text("\(Int(fuelPercentage))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fuelPercentage, in: 0 ... 100, step: 1)
                        .onChange(of: fuelPercentage) { _, _ in updateGasRange() }
                }
            } header: {
                Text("Power/Fuel")
            }

            Section {
                HStack {
                    Text("Odometer")
                    Spacer()
                    Text("\(Int(odometer)) mi")
                        .foregroundColor(.secondary)
                }
                Slider(value: $odometer, in: 0 ... 200_000, step: 100)
                    .onChange(of: odometer) { _, newValue in
                        vehicle.odometer = Distance(length: newValue, units: .miles)
                        saveChanges()
                    }
            } header: {
                Text("Vehicle Status")
            }

            Section {
                HStack {
                    Text("Latitude")
                    Spacer()
                    TextField("", value: $latitude, format: .number.precision(.fractionLength(4)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .onChange(of: latitude) { _, _ in updateLocation() }
                }
                HStack {
                    Text("Longitude")
                    Spacer()
                    TextField("", value: $longitude, format: .number.precision(.fractionLength(4)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .onChange(of: longitude) { _, _ in updateLocation() }
                }
            } header: {
                Text("Location")
            }

            Section {
                Toggle("Locked", isOn: $isLocked)
                    .onChange(of: isLocked) { _, newValue in
                        vehicle.lockStatus = newValue ? .locked : .unlocked
                        saveChanges()
                    }

                Toggle("Climate On", isOn: $climateOn)
                    .onChange(of: climateOn) { _, _ in updateClimate() }

                if climateOn {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text("\(Int(temperature))°F")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $temperature, in: 50 ... 85, step: 1)
                        .onChange(of: temperature) { _, _ in updateClimate() }
                }
            } header: {
                Text("Status")
            }
        }
        .navigationTitle("Vehicle Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadVehicleData()
        }
    }

    private func loadVehicleData() {
        modelName = vehicle.model
        odometer = vehicle.odometer.length
        isLocked = vehicle.lockStatus == .locked

        // Determine vehicle type based on what systems are present
        let hasEV = vehicle.evStatus != nil
        let hasGas = vehicle.gasRange != nil

        if hasEV, hasGas {
            vehicleType = .pluginHybrid
        } else if hasEV {
            vehicleType = .electric
        } else {
            vehicleType = .gas
        }

        if let location = vehicle.location {
            latitude = location.latitude
            longitude = location.longitude
        }

        if let climateStatus = vehicle.climateStatus {
            climateOn = climateStatus.airControlOn
            temperature = climateStatus.temperature.value
        }

        if let evStatus = vehicle.evStatus {
            batteryPercentage = evStatus.evRange.percentage
            isCharging = evStatus.charging
            chargeSpeed = evStatus.chargeSpeed
            isPluggedIn = evStatus.pluggedIn
        }

        if let gasRange = vehicle.gasRange {
            fuelPercentage = gasRange.percentage
        }
    }

    private func updateVehicleType() {
        // Update isElectric flag based on vehicle type
        vehicle.isElectric = vehicleType == .electric || vehicleType == .pluginHybrid

        switch vehicleType {
        case .gas:
            // Gas only - set up gas range, remove EV status
            let gasRangeDistance = Distance(length: fuelPercentage * 4.0, units: .miles)
            vehicle.gasRange = VehicleStatus.FuelRange(
                range: gasRangeDistance,
                percentage: fuelPercentage
            )
            vehicle.evStatus = nil

        case .electric:
            // Electric only - set up EV status, remove gas range
            let evRange = Distance(length: batteryPercentage * 3.0, units: .miles)
            vehicle.evStatus = VehicleStatus.EVStatus(
                charging: isCharging,
                chargeSpeed: chargeSpeed,
                pluggedIn: isPluggedIn,
                evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage)
            )
            vehicle.gasRange = nil

        case .pluginHybrid:
            // Plug-in hybrid - set up both gas and EV status
            let gasRangeDistance = Distance(length: fuelPercentage * 4.0, units: .miles)
            vehicle.gasRange = VehicleStatus.FuelRange(
                range: gasRangeDistance,
                percentage: fuelPercentage
            )

            let evRange = Distance(length: batteryPercentage * 3.0, units: .miles)
            vehicle.evStatus = VehicleStatus.EVStatus(
                charging: isCharging,
                chargeSpeed: chargeSpeed,
                pluggedIn: isPluggedIn,
                evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage)
            )
        }

        saveChanges()
    }

    private func updateEVStatus() {
        guard hasElectric else { return }
        let evRange = Distance(length: batteryPercentage * 3.0, units: .miles)
        vehicle.evStatus = VehicleStatus.EVStatus(
            charging: isCharging,
            chargeSpeed: isCharging ? chargeSpeed : 0.0,
            pluggedIn: isPluggedIn,
            evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage)
        )
        saveChanges()
    }

    private func updateGasRange() {
        guard hasGas else { return }
        let gasRangeDistance = Distance(length: fuelPercentage * 4.0, units: .miles)
        vehicle.gasRange = VehicleStatus.FuelRange(
            range: gasRangeDistance,
            percentage: fuelPercentage
        )
        saveChanges()
    }

    private func updateLocation() {
        vehicle.location = VehicleStatus.Location(latitude: latitude, longitude: longitude)
        saveChanges()
    }

    private func updateClimate() {
        vehicle.climateStatus = VehicleStatus.ClimateStatus(
            defrostOn: climateOn,
            airControlOn: climateOn,
            steeringWheelHeatingOn: false,
            temperature: Temperature(value: temperature, units: .fahrenheit),
        )
        saveChanges()
    }

    private func saveChanges() {
        vehicle.lastUpdated = Date()
        do {
            try modelContext.save()
        } catch {
            print("Failed to save vehicle changes: \(error)")
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            let testAccount = BBAccount(
                username: "test@example.com",
                password: "password",
                pin: "1234",
                brand: .fake,
                region: .usa
            )

            let testVehicle = BBVehicle(from: Vehicle(
                vin: "FAKE123456789",
                regId: "FAKE123",
                model: "Test Vehicle",
                accountId: testAccount.id,
                isElectric: true,
                generation: 3,
                odometer: Distance(length: 15000, units: .miles)
            ))

            NavigationView {
                FakeVehicleDetailView(vehicle: testVehicle)
            }
            .modelContainer(for: [BBAccount.self, BBVehicle.self])
        }
    }
    return PreviewWrapper()
}
