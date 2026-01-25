//
//  ClimatePresetsSection.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct ClimatePresetsSection: View {
    let bbVehicle: BBVehicle
    let vehiclePresets: [ClimatePreset]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if !vehiclePresets.isEmpty {
            Section {
                ForEach(vehiclePresets, id: \.id) { preset in
                    HStack(spacing: 0) {
                        Button {
                            selectPreset(preset)
                        } label: {
                            Image(systemName: preset.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(preset.isSelected ? .green : .gray)
                                .frame(width: 32)
                        }
                        .buttonStyle(.plain)

                        NavigationLink(destination: ClimateSettingsContent(vehicle: bbVehicle, preset: preset)) {
                            HStack {
                                Image(systemName: preset.iconName)
                                    .foregroundColor(.blue)
                                    .frame(width: 20)

                                Text(preset.name)
                                    .font(.subheadline)

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
                .onMove(perform: movePresets)
                .onDelete(perform: deletePresets)
            } header: {
                HStack {
                    Text("Climate Presets")
                    Spacer()
                    Button("Add Preset") {
                        createNewPreset()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
        }
    }

    private func movePresets(from source: IndexSet, to destination: Int) {
        var presets = Array(vehiclePresets)
        presets.move(fromOffsets: source, toOffset: destination)

        for (index, preset) in presets.enumerated() {
            preset.sortOrder = index
        }

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "ClimatePresetsSection: Failed to update preset order: \(error)")
        }
    }

    private func deletePresets(offsets: IndexSet) {
        guard vehiclePresets.count > 1 else { return }

        for index in offsets {
            let preset = vehiclePresets[index]
            let wasSelected = preset.isSelected

            modelContext.delete(preset)

            if wasSelected {
                let remainingPresets = vehiclePresets.filter { $0.id != preset.id }
                remainingPresets.first?.isSelected = true
            }
        }

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "ClimatePresetsSection: Failed to delete preset: \(error)")
        }
    }

    private func createNewPreset() {
        let randomIcon = ClimatePreset.availableIcons.randomElement()?.icon ?? "fan"
        let newPreset = ClimatePreset(
            name: "Preset \(vehiclePresets.count + 1)",
            iconName: randomIcon,
            climateOptions: ClimateOptions(),
            isSelected: false,
            vehicleId: bbVehicle.id,
        )
        newPreset.sortOrder = vehiclePresets.count
        modelContext.insert(newPreset)

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "ClimatePresetsSection: Failed to create preset: \(error)")
        }
    }

    private func selectPreset(_ preset: ClimatePreset) {
        for other in vehiclePresets {
            other.isSelected = false
        }
        preset.isSelected = true

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "ClimatePresetsSection: Failed to select preset: \(error)")
        }
    }
}
