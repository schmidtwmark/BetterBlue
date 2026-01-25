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
    @State private var plugType: VehicleStatus.PlugType = .unplugged
    @State private var chargeTimeMinutes: Double = 0
    @State private var targetSocAC: Double = 80
    @State private var targetSocDC: Double = 90
    @State private var latitude: Double = 37.7749
    @State private var longitude: Double = -122.4194

    // Additional status fields
    @State private var battery12V: Double = 80
    @State private var frontLeftDoorOpen: Bool = false
    @State private var frontRightDoorOpen: Bool = false
    @State private var backLeftDoorOpen: Bool = false
    @State private var backRightDoorOpen: Bool = false
    @State private var trunkOpen: Bool = false
    @State private var hoodOpen: Bool = false
    @State private var tirePressureWarningFL: Bool = false
    @State private var tirePressureWarningFR: Bool = false
    @State private var tirePressureWarningRL: Bool = false
    @State private var tirePressureWarningRR: Bool = false

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

                    Picker("Plug Type", selection: $plugType) {
                        Text("Unplugged").tag(VehicleStatus.PlugType.unplugged)
                        Text("AC Charger").tag(VehicleStatus.PlugType.acCharger)
                        Text("DC Charger").tag(VehicleStatus.PlugType.dcCharger)
                    }
                    .onChange(of: plugType) { _, _ in updateEVStatus() }

                    if isCharging {
                        HStack {
                            Text("Charge Speed")
                            Spacer()
                            Text("\(Int(chargeSpeed)) kW")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $chargeSpeed, in: 0 ... 250, step: 1)
                            .onChange(of: chargeSpeed) { _, _ in updateEVStatus() }

                        HStack {
                            Text("Charge Time Remaining")
                            Spacer()
                            Text("\(Int(chargeTimeMinutes)) min")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $chargeTimeMinutes, in: 0 ... 480, step: 5)
                            .onChange(of: chargeTimeMinutes) { _, _ in updateEVStatus() }
                    }

                    HStack {
                        Text("Target SOC (AC)")
                        Spacer()
                        Text("\(Int(targetSocAC))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $targetSocAC, in: 50 ... 100, step: 5)
                        .onChange(of: targetSocAC) { _, _ in updateEVStatus() }

                    HStack {
                        Text("Target SOC (DC)")
                        Spacer()
                        Text("\(Int(targetSocDC))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $targetSocDC, in: 50 ... 100, step: 5)
                        .onChange(of: targetSocDC) { _, _ in updateEVStatus() }
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

            Section {
                HStack {
                    Text("12V Battery")
                    Spacer()
                    Text("\(Int(battery12V))%")
                        .foregroundColor(battery12V < 50 ? .orange : .secondary)
                }
                Slider(value: $battery12V, in: 0 ... 100, step: 1)
                    .onChange(of: battery12V) { _, _ in updateAdditionalStatus() }
            } header: {
                Text("12V Battery")
            }

            Section {
                Toggle("Front Left", isOn: $frontLeftDoorOpen)
                    .onChange(of: frontLeftDoorOpen) { _, _ in updateDoorStatus() }
                Toggle("Front Right", isOn: $frontRightDoorOpen)
                    .onChange(of: frontRightDoorOpen) { _, _ in updateDoorStatus() }
                Toggle("Back Left", isOn: $backLeftDoorOpen)
                    .onChange(of: backLeftDoorOpen) { _, _ in updateDoorStatus() }
                Toggle("Back Right", isOn: $backRightDoorOpen)
                    .onChange(of: backRightDoorOpen) { _, _ in updateDoorStatus() }
                Toggle("Trunk", isOn: $trunkOpen)
                    .onChange(of: trunkOpen) { _, newValue in
                        vehicle.trunkOpen = newValue
                        saveChanges()
                    }
                Toggle("Hood", isOn: $hoodOpen)
                    .onChange(of: hoodOpen) { _, newValue in
                        vehicle.hoodOpen = newValue
                        saveChanges()
                    }
            } header: {
                Text("Doors & Openings")
            }

            Section {
                Toggle("Front Left", isOn: $tirePressureWarningFL)
                    .onChange(of: tirePressureWarningFL) { _, _ in updateTirePressure() }
                Toggle("Front Right", isOn: $tirePressureWarningFR)
                    .onChange(of: tirePressureWarningFR) { _, _ in updateTirePressure() }
                Toggle("Rear Left", isOn: $tirePressureWarningRL)
                    .onChange(of: tirePressureWarningRL) { _, _ in updateTirePressure() }
                Toggle("Rear Right", isOn: $tirePressureWarningRR)
                    .onChange(of: tirePressureWarningRR) { _, _ in updateTirePressure() }
            } header: {
                Text("Tire Pressure Warnings")
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
            plugType = evStatus.plugType
            chargeTimeMinutes = Double(evStatus.chargeTime.components.seconds / 60)
            targetSocAC = evStatus.targetSocAC ?? 80
            targetSocDC = evStatus.targetSocDC ?? 90
        }

        if let gasRange = vehicle.gasRange {
            fuelPercentage = gasRange.percentage
        }

        // Load additional status fields
        battery12V = Double(vehicle.battery12V ?? 80)

        if let doorOpen = vehicle.doorOpen {
            frontLeftDoorOpen = doorOpen.frontLeft
            frontRightDoorOpen = doorOpen.frontRight
            backLeftDoorOpen = doorOpen.backLeft
            backRightDoorOpen = doorOpen.backRight
        }

        trunkOpen = vehicle.trunkOpen ?? false
        hoodOpen = vehicle.hoodOpen ?? false

        if let tirePressure = vehicle.tirePressureWarning {
            tirePressureWarningFL = tirePressure.frontLeft
            tirePressureWarningFR = tirePressure.frontRight
            tirePressureWarningRL = tirePressure.rearLeft
            tirePressureWarningRR = tirePressure.rearRight
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
                evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage),
                plugType: plugType,
                chargeTime: .seconds(Int64(chargeTimeMinutes * 60)),
                targetSocAC: targetSocAC,
                targetSocDC: targetSocDC
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
                evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage),
                plugType: plugType,
                chargeTime: .seconds(Int64(chargeTimeMinutes * 60)),
                targetSocAC: targetSocAC,
                targetSocDC: targetSocDC
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
            evRange: VehicleStatus.FuelRange(range: evRange, percentage: batteryPercentage),
            plugType: plugType,
            chargeTime: .seconds(Int64(chargeTimeMinutes * 60)),
            targetSocAC: targetSocAC,
            targetSocDC: targetSocDC
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
            temperature: Temperature(value: temperature, units: .fahrenheit)
        )
        saveChanges()
    }

    private func updateAdditionalStatus() {
        vehicle.battery12V = Int(battery12V)
        saveChanges()
    }

    private func updateDoorStatus() {
        vehicle.doorOpen = VehicleStatus.DoorStatus(
            frontLeft: frontLeftDoorOpen,
            frontRight: frontRightDoorOpen,
            backLeft: backLeftDoorOpen,
            backRight: backRightDoorOpen
        )
        saveChanges()
    }

    private func updateTirePressure() {
        vehicle.tirePressureWarning = VehicleStatus.TirePressureWarning(
            frontLeft: tirePressureWarningFL,
            frontRight: tirePressureWarningFR,
            rearLeft: tirePressureWarningRL,
            rearRight: tirePressureWarningRR,
            all: false
        )
        saveChanges()
    }

    private func saveChanges() {
        vehicle.lastUpdated = Date()
        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "Failed to save vehicle changes: \(error)")
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
