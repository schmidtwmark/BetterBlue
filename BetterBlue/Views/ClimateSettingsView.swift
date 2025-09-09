//
//  ClimateSettingsView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct ClimateSettingsContent: View {
    let vehicle: BBVehicle
    let preset: ClimatePreset
    @State private var appSettings = AppSettings.shared
    @Environment(\.modelContext) private var modelContext
    @Query private var allClimatePresets: [ClimatePreset]
    @State private var editingName = false
    @State private var newName = ""

    private var vehiclePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicleId == vehicle.id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        List {
            // Preset info section with editable name and icon
            Section("Preset Info") {
                HStack {
                    Menu {
                        ForEach(ClimatePreset.availableIcons, id: \.icon) { option in
                            Button {
                                preset.iconName = option.icon
                                savePreset(preset)
                            } label: {
                                Label(option.name, systemImage: option.icon)
                            }
                        }
                    } label: {
                        Image(systemName: preset.iconName)
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(width: 32)
                    }

                    Button {
                        newName = preset.name
                        editingName = true
                    } label: {
                        Text(preset.name)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }

                    Spacer()

                    if vehiclePresets.count > 1 {
                        Button(preset.isSelected ? "Selected" : "Use Preset") {
                            selectPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .disabled(preset.isSelected)
                    }
                }
            }

            climateControlsSection

            // Delete button (only if there are multiple presets)
            if vehiclePresets.count > 1 {
                Section {
                    Button("Delete Preset", role: .destructive) {
                        deleteCurrentPreset()
                    }
                }
            }
        }
        .navigationTitle("Climate Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            createDefaultPresetIfNeeded()
        }
        .alert("Edit Preset Name", isPresented: $editingName) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                preset.name = newName
                savePreset(preset)
            }
        }
    }

    var defrostIcon: String {
        preset.climateOptions.defrost ?
            "windshield.front.and.heat.waves" : "windshield.front.and.wiper"
    }

    var defrostColor: Color {
        preset.climateOptions.defrost ? Color.orange : Color.secondary
    }

    @ViewBuilder
    private var climateControlsSection: some View {
        // Temperature Section
        Section("HVAC") {
            TemperatureArcControl(
                temperature: Binding(
                    get: { preset.climateOptions.temperature },
                    set: { newValue in
                        preset.climateOptions.temperature = newValue
                        savePreset(preset)
                    },
                ),
                preferredUnit: appSettings.preferredTemperatureUnit,
            )
            .frame(height: 250)
            .padding(.bottom, -20)
            HStack(spacing: 16) {
                // Defrost icon
                Image(systemName: defrostIcon)
                    .font(.title2)
                    .foregroundColor(defrostColor)
                    .frame(width: 32)

                // Text and toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Defrost")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(preset.climateOptions.defrost ? "On" : "Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { preset.climateOptions.defrost },
                        set: { newValue in
                            preset.climateOptions.defrost = newValue
                            savePreset(preset)
                        },
                    ))
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                preset.climateOptions.defrost ?
                    Color.orange.opacity(0.1) :
                    Color.clear,
            )
            .animation(.easeInOut(duration: 0.2), value: preset.climateOptions.defrost)
            .listRowInsets(EdgeInsets())
        }

        // Heated Steering Wheel Section
        Section("Accessories") {
            HStack(spacing: 16) {
                // Steering wheel icon
                Image(systemName: preset.climateOptions.steeringWheel > 0 ?
                    "steeringwheel.and.heat.waves" : "steeringwheel")
                    .font(.title2)
                    .foregroundColor(preset.climateOptions.steeringWheel > 0 ? Color.orange : Color.secondary)
                    .frame(width: 32)

                // Text and toggle
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Steering Wheel Heat")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(preset.climateOptions.steeringWheel > 0 ? "On" : "Off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { preset.climateOptions.steeringWheel > 0 },
                        set: { isOn in
                            preset.climateOptions.steeringWheel = isOn ? 1 : 0
                            savePreset(preset)
                        },
                    ))
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                preset.climateOptions.steeringWheel > 0 ?
                    Color.orange.opacity(0.1) :
                    Color.clear,
            )
            .animation(.easeInOut(duration: 0.2), value: preset.climateOptions.steeringWheel)
            .listRowInsets(EdgeInsets())
        }

        if vehicle.generation >= 3 {
            Section("Front Seats") {
                HStack(spacing: 0) {
                    SeatHeatControl(
                        level: Binding(
                            get: { preset.climateOptions.frontLeftSeat },
                            set: { newValue in
                                preset.climateOptions.frontLeftSeat = newValue
                                savePreset(preset)
                            },
                        ),
                        position: "left",
                    )

                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 0.5)

                    SeatHeatControl(
                        level: Binding(
                            get: { preset.climateOptions.frontRightSeat },
                            set: { newValue in
                                preset.climateOptions.frontRightSeat = newValue
                                savePreset(preset)
                            },
                        ),
                        position: "right",
                    )
                }
                .listRowInsets(EdgeInsets())
            }
            Section("Rear Seats") {
                HStack(spacing: 0) {
                    SeatHeatControl(
                        level: Binding(
                            get: { preset.climateOptions.rearLeftSeat },
                            set: { newValue in
                                preset.climateOptions.rearLeftSeat = newValue
                                savePreset(preset)
                            },
                        ),
                        position: "left",
                    )

                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 0.5)

                    SeatHeatControl(
                        level: Binding(
                            get: { preset.climateOptions.rearRightSeat },
                            set: { newValue in
                                preset.climateOptions.rearRightSeat = newValue
                                savePreset(preset)
                            },
                        ),
                        position: "right",
                    )
                }
                .listRowInsets(EdgeInsets())
            }
        }
    }
}

// MARK: - ClimateSettingsContent Extensions

extension ClimateSettingsContent {
    private func createDefaultPresetIfNeeded() {
        if vehiclePresets.isEmpty {
            let defaultPreset = ClimatePreset(
                name: "Default",
                iconName: "fan",
                climateOptions: ClimateOptions(),
                isSelected: true,
                vehicleId: vehicle.id,
            )
            modelContext.insert(defaultPreset)
            try? modelContext.save()
        }
    }

    private func selectPreset(_ preset: ClimatePreset) {
        // Deselect all presets for this vehicle
        for other in vehiclePresets {
            other.isSelected = false
        }
        // Select the chosen preset
        preset.isSelected = true
        try? modelContext.save()
    }

    private func deleteCurrentPreset() {
        guard vehiclePresets.count > 1 else { return }

        let wasSelected = preset.isSelected
        modelContext.delete(preset)

        // If we deleted the selected preset, select the first remaining one
        if wasSelected {
            let remainingPresets = vehiclePresets.filter { $0.id != preset.id }
            remainingPresets.first?.isSelected = true
        }

        try? modelContext.save()
    }

    private func savePreset(_: ClimatePreset) {
        try? modelContext.save()
    }
}

#Preview {
    let sampleVehicle = BBVehicle(from: Vehicle(
        vin: "testVin",
        regId: "testRegId",
        model: "Ioniq 5",
        accountId: UUID(),
        isElectric: true,
        generation: 3,
        odometer: .init(length: 500, units: .miles),
        vehicleKey: nil,
    ))

    ClimateSettingsSheet(vehicle: sampleVehicle)
        .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self])
}
