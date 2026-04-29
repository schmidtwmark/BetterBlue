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
                    #if os(iOS)
                    .autocapitalization(.words)
                    #endif
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

            // Menu Bar Icon — shown on all platforms even though the Mac
            // menu bar is the only surface that consumes it today. The
            // setting travels with the vehicle via iCloud so a user who
            // picks an icon on iPhone will see it reflected when they
            // later enable the menu bar app on Mac.
            Section {
                Menu {
                    ForEach(BBVehicle.availableMenuBarIcons, id: \.icon) { option in
                        Button {
                            bbVehicle.menuBarIconName = option.icon
                            try? modelContext.save()
                        } label: {
                            Label(option.name, systemImage: option.icon)
                        }
                    }
                } label: {
                    HStack {
                        Text("Menu Bar Icon")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: bbVehicle.menuBarIconName)
                            .foregroundColor(.blue)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Icon used when the Mac menu bar app is enabled.")
            }

            if let account = bbVehicle.account {
                Section("Account Info") {
                    NavigationLink(account.username, destination: AccountInfoView(
                        account: account,
                    ))
                }
            }

            // Climate Settings (only for older vehicles)
            if bbVehicle.generation < 3 {
                Section {
                    Toggle(isOn: Binding(
                        get: { bbVehicle.enableSeatHeatControls },
                        set: { newValue in
                            bbVehicle.enableSeatHeatControls = newValue
                            try? modelContext.save()
                        }
                    )) {
                        HStack {
                            Text("Seat Heat Controls")
                            SeatHeatInfoButton()
                        }
                    }
                } header: {
                    Text("Climate Settings")
                } footer: {
                    Text("Enable seat heating and cooling controls for vehicles that support them.")
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

            #if DEBUG && os(iOS)
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

// MARK: - Seat Heat Info Button

private struct SeatHeatInfoButton: View {
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
        }
        .buttonStyle(.plain)
        .alert("Seat Heat Controls", isPresented: $showingInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Seat heating and cooling controls are automatically available for newer " +
                "vehicles (generation 3+). Some older vehicles also support these features " +
                "but require manual enabling.\n\n" +
                "If your vehicle has heated or ventilated seats, you can enable this option " +
                "to show seat controls in your climate presets. If your vehicle doesn't " +
                "support these features, the controls will have no effect."
            )
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
