//
//  WatchVehicleSettingsView.swift
//  BetterBlueWatch Watch App
//
//  Vehicle settings for Apple Watch
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct WatchVehicleSettingsView: View {
    let vehicle: BBVehicle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared
    @State private var showingDiagnostics = false

    // Get the latest vehicle from the query
    @Query private var allVehicles: [BBVehicle]
    private var currentVehicle: BBVehicle {
        allVehicles.first(where: { $0.vin == vehicle.vin }) ?? vehicle
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Distance", selection: $appSettings.preferredDistanceUnit) {
                        ForEach([Distance.Units.miles, Distance.Units.kilometers], id: \.self) { unit in
                            Text(unit.rawValue.capitalized)
                                .tag(unit)
                        }
                    }
                }
                Section("Watch Background") {
                    ForEach(BBVehicle.availableWatchBackgrounds, id: \.name) { background in
                        Button {
                            updateWatchBackground(to: background.name)
                        } label: {
                            HStack {
                                // Background preview
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(
                                        gradient: Gradient(colors: background.gradient),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing,
                                    ))
                                    .frame(width: 24, height: 16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.primary.opacity(0.3), lineWidth: 0.5),
                                    )

                                Text(background.displayName)
                                    .foregroundColor(.primary)

                                Spacer()

                                if currentVehicle.watchBackgroundColorName == background.name {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Debug") {
                    Button {
                        showingDiagnostics = true
                    } label: {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("Sync Diagnostics")
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticInfoView()
            }
        }
    }

    private func updateWatchBackground(to colorName: String) {
        currentVehicle.watchBackgroundColorName = colorName

        do {
            try modelContext.save()
        } catch {
            print("❌ [WatchSettings] Failed to save watch background: \(error)")
        }
    }
}

#Preview {
    let schema = Schema([
        BBAccount.self,
        BBVehicle.self,
        BBHTTPLog.self,
        ClimatePreset.self
    ])
    let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Failed to create ModelContainer for preview: \(error)")
        }
    }()

    let sampleVehicle = BBVehicle(from: Vehicle(
        vin: "test",
        regId: "test",
        model: "Ioniq 5",
        accountId: UUID(),
        isElectric: true,
        generation: 3,
        odometer: Distance(length: 25000, units: .miles),
        vehicleKey: nil,
    ), backgroundColorName: "lightBlue")

    WatchVehicleSettingsView(vehicle: sampleVehicle)
        .modelContainer(container)
}
