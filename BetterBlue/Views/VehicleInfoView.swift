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
    @State private var appSettings = AppSettings.shared
    @Query private var allClimatePresets: [ClimatePreset]

    private var vehiclePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicle?.id == bbVehicle.id }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Three-way visibility choice, mapped onto the vehicle's optional
    /// `surroundViewOverride` (nil = automatic).
    private enum SurroundViewChoice { case automatic, show, hide }

    private var surroundViewChoice: Binding<SurroundViewChoice> {
        Binding(
            get: {
                switch bbVehicle.surroundViewOverride {
                case .none: .automatic
                case .some(true): .show
                case .some(false): .hide
                }
            },
            set: { choice in
                switch choice {
                case .automatic: bbVehicle.surroundViewOverride = nil
                case .show: bbVehicle.surroundViewOverride = true
                case .hide: bbVehicle.surroundViewOverride = false
                }
            }
        )
    }

    var body: some View {
        PersistentModelGuard(model: bbVehicle) {
            activeBody
        }
    }

    @ViewBuilder
    private var activeBody: some View {
        Form {
            VehicleBasicInfoSection(
                bbVehicle: bbVehicle,
                showingCopiedMessage: $showingCopiedMessage
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
            
            VehicleCustomizationSection(bbVehicle: bbVehicle)
            
            
            if let account = bbVehicle.account {
                Section("Account Info") {
                    NavigationLink(account.username, destination: AccountInfoView(
                        account: account,
                    ))
                }
            }

            if bbVehicle.account?.supportsSurroundView == true {
                Section {
                    Picker("Surround View", selection: surroundViewChoice) {
                        Text("Automatic").tag(SurroundViewChoice.automatic)
                        Text("Always Show").tag(SurroundViewChoice.show)
                        Text("Always Hide").tag(SurroundViewChoice.hide)
                    }
                } header: {
                    Text("Surround View")
                } footer: {
                    Text(bbVehicle.autoShowsSurroundView
                        ? "Automatic shows the surround view menu for this vehicle. Override it if your vehicle doesn't have the cameras."
                        : "Automatic hides the surround view menu for this vehicle's generation. Override it if your vehicle does have the cameras.")
                }
            }
            
            // Climate Settings — toggles + info button extracted into
            // shared components so the same controls back the toolbar
            // half-sheet on `ClimateSettingsContent` for older vehicles.
            if bbVehicle.generation < 3 {
                Section {
                    ClimateSettingsToggles(bbVehicle: bbVehicle)
                } header: {
                    HStack {
                        Text("Climate Settings")
                        Spacer()
                        ClimateSettingsInfoButton()
                    }
                }
            }

            ClimatePresetsSection(bbVehicle: bbVehicle, vehiclePresets: vehiclePresets)

            // EV Settings (only for electric vehicles)
            if bbVehicle.fuelType.hasElectricCapability {
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

            #if DEBUG
            Toggle("Debug Live Activity", isOn: Binding(
                get: { bbVehicle.debugLiveActivity },
                set: { newValue in
                    bbVehicle.debugLiveActivity = newValue
                    try? modelContext.save()
                    LiveActivityManager.shared.updateDebugActivity(for: bbVehicle)
                }
            ))

            #endif

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
                climateOptions: ClimateOptions(preferredUnits: AppSettings.shared.preferredTemperatureUnit),
                isSelected: true,
                vehicle: bbVehicle
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

            NavigationView {
                VehicleInfoView(bbVehicle: testVehicle)
            }
            .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self])
        }
    }
    return PreviewWrapper()
}
