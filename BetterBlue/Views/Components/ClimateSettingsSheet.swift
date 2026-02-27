//
//  ClimateSettingsSheet.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct ClimateSettingsSheet: View {
    let vehicle: BBVehicle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allClimatePresets: [ClimatePreset]
    @State private var selectedTab = 0
    @State private var showingNewPresetAlert = false
    @State private var newPresetName = ""
    @State private var newPresetIcon = "fan"

    private var vehiclePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicle?.id == vehicle.id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                ForEach(Array(vehiclePresets.enumerated()), id: \.1.id) { index, preset in
                    ClimateSettingsContent(vehicle: vehicle, preset: preset)
                        .tabItem {
                            Label(preset.name, systemImage: preset.iconName)
                        }
                        .tag(index)
                }
            }
            .tabViewStyle(.tabBarOnly)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("New") {
                        createNewPreset()
                    }
                }
            }
            .navigationTitle("Climate Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            createDefaultPresetIfNeeded()
        }
    }
}

// MARK: - ClimateSettingsSheet Extensions

extension ClimateSettingsSheet {
    private func createDefaultPresetIfNeeded() {
        if vehiclePresets.isEmpty {
            let defaultPreset = ClimatePreset(
                name: "Default",
                iconName: "fan",
                climateOptions: ClimateOptions(),
                isSelected: true,
                vehicle: vehicle
            )
            modelContext.insert(defaultPreset)
            try? modelContext.save()
        }
    }

    private func createNewPreset() {
        let randomIcon = ClimatePreset.availableIcons.randomElement()?.icon ?? "fan"
        let newPreset = ClimatePreset(
            name: "Preset \(vehiclePresets.count + 1)",
            iconName: randomIcon,
            climateOptions: ClimateOptions(),
            isSelected: false,
            vehicle: vehicle
        )
        let newIndex = vehiclePresets.count
        newPreset.sortOrder = newIndex
        modelContext.insert(newPreset)
        try? modelContext.save()

        // Select the new preset tab with animation after a short delay to ensure it's created
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedTab = newIndex
            }
        }
    }
}
