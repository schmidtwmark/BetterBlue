//
//  VehicleInfoView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/7/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct VehicleInfoView: View {
    let bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var customName: String = ""
    @State private var showingCopiedMessage = false
    @State private var showingCopiedMileageMessage = false
    @State private var appSettings = AppSettings.shared
    @Query private var allClimatePresets: [ClimatePreset]

    private var vehiclePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicleId == bbVehicle.id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Form {
            VehicleBasicInfoSection(
                bbVehicle: bbVehicle,
                showingCopiedMessage: $showingCopiedMessage,
                showingCopiedMileageMessage: $showingCopiedMileageMessage,
            )

            Section("Custom Name") {
                TextField("Vehicle Name", text: $customName)
                    .autocapitalization(.words)
                    .onChange(of: customName) { _, newValue in
                        bbVehicle.customName = newValue.isEmpty ? nil : newValue
                        do {
                            try modelContext.save()
                        } catch {
                            BBLogger.error(.app, "Failed to save custom name: \(error)")
                        }
                    }
            }

            VehicleWidgetConfigSection(bbVehicle: bbVehicle)

            if let account = bbVehicle.account {
                Section("Account Info") {
                    NavigationLink(account.username, destination: AccountInfoView(
                        account: account,
                    ))
                }
            }

            // EV Settings (only for electric vehicles)
            if bbVehicle.isElectric {
                Section("EV Settings") {
                    Picker("Charge Port Type", selection: Binding(
                        get: { bbVehicle.chargePortType },
                        set: { newValue in
                            bbVehicle.chargePortType = newValue
                            try? modelContext.save()
                        }
                    )) {
                        ForEach(ChargePortType.allCases, id: \.self) { portType in
                            Label(portType.displayName, systemImage: portType.dcPlugIcon).tag(portType)
                        }
                    }

                    NavigationLink(destination: ChargeLimitSettingsContent(vehicle: bbVehicle)) {
                        HStack {
                            Text("Charge Limits")
                            Spacer()
                            if let evStatus = bbVehicle.evStatus,
                               let acTarget = evStatus.targetSocAC,
                               let dcTarget = evStatus.targetSocDC {
                                Text("AC: \(Int(acTarget))% / DC: \(Int(dcTarget))%")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            // Fake Vehicle Configuration (only for fake vehicles)
            if let account = bbVehicle.account, account.brandEnum == .fake {
                Section("Fake Vehicle Configuration") {
                    NavigationLink("Configure Vehicle", destination: FakeVehicleDetailView(vehicle: bbVehicle))
                }
            }

            // Debug section (only when debug mode is enabled)
            if appSettings.debugModeEnabled {
                Section {
                    Toggle("Debug Live Activity", isOn: Binding(
                        get: { bbVehicle.debugLiveActivity },
                        set: { newValue in
                            bbVehicle.debugLiveActivity = newValue
                            try? modelContext.save()
                            LiveActivityManager.shared.updateDebugActivity(for: bbVehicle)
                        }
                    ))
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Shows a debug Live Activity that displays wakeup count and timing information for testing push notifications.")
                }
            }

            ClimatePresetsSection(bbVehicle: bbVehicle, vehiclePresets: vehiclePresets)
        }
        .navigationTitle("Vehicle Info")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if showingCopiedMessage {
                Text("VIN copied to clipboard")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
            }

            if showingCopiedMileageMessage {
                Text("Mileage copied to clipboard")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
            }
        }
        .navigationTitle("Vehicle Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customName = bbVehicle.customName ?? ""
            createDefaultPresetIfNeeded()
        }
    }

    private func createDefaultPresetIfNeeded() {
        if vehiclePresets.isEmpty {
            let defaultPreset = ClimatePreset(
                name: "Default",
                iconName: "fan",
                climateOptions: ClimateOptions(),
                isSelected: true,
                vehicleId: bbVehicle.id,
            )
            defaultPreset.sortOrder = 0
            modelContext.insert(defaultPreset)

            do {
                try modelContext.save()
            } catch {
                BBLogger.error(.app, "Failed to create default preset: \(error)")
            }
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

            NavigationView {
                VehicleInfoView(bbVehicle: testVehicle)
            }
            .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self])
        }
    }
    return PreviewWrapper()
}
