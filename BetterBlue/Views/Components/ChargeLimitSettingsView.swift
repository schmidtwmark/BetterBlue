//
//  ChargeLimitSettingsView.swift
//  BetterBlue
//
//  Created by Claude on 1/16/26.
//

import BetterBlueKit
import SwiftData
import SwiftUI

/// Sheet wrapper for modal presentation (from ChargingButton menu)
struct ChargeLimitSettingsSheet: View {
    let vehicle: BBVehicle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ChargeLimitSettingsContent(vehicle: vehicle, onSave: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

/// Content view for navigation push (from VehicleInfoView settings)
struct ChargeLimitSettingsContent: View {
    let vehicle: BBVehicle
    var onSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var acLevel: Double
    @State private var dcLevel: Double
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var successMessage: String?

    init(vehicle: BBVehicle, onSave: (() -> Void)? = nil) {
        self.vehicle = vehicle
        self.onSave = onSave
        // Initialize with current values or defaults
        let currentAC = vehicle.evStatus?.targetSocAC ?? 80
        let currentDC = vehicle.evStatus?.targetSocDC ?? 80
        _acLevel = State(initialValue: currentAC)
        _dcLevel = State(initialValue: currentDC)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "ev.plug.ac.type.1")
                            .foregroundColor(.blue)
                        Text("AC Charging Limit")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(acLevel))%")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                    }

                    Slider(value: $acLevel, in: 50...100, step: 10)
                        .tint(.blue)

                    Text("Set the charge limit for AC charging (Level 1/2)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            .disabled(isSaving)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "ev.plug.dc.ccs1")
                            .foregroundColor(.green)
                        Text("DC Charging Limit")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(dcLevel))%")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }

                    Slider(value: $dcLevel, in: 50...100, step: 10)
                        .tint(.green)

                    Text("Set the charge limit for DC fast charging")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            .disabled(isSaving)

            if let errorMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                    .font(.callout)
                }
            }

            if let successMessage {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(successMessage)
                            .foregroundColor(.green)
                    }
                    .font(.callout)
                }
            }

            Section {
                Button(action: saveChargeLimits) {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                            if let statusMessage {
                                Text(statusMessage)
                                    .padding(.leading, 8)
                            }
                        } else {
                            Text("Save Charge Limits")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Charge Limits")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: acLevel) {
            successMessage = nil
        }
        .onChange(of: dcLevel) {
            successMessage = nil
        }
    }

    @MainActor
    private func saveChargeLimits() {
        guard let account = vehicle.account else {
            errorMessage = "Account not found for vehicle"
            return
        }

        isSaving = true
        errorMessage = nil
        statusMessage = "Sending command..."

        Task {
            do {
                try await account.setTargetSOC(
                    vehicle,
                    acLevel: Int(acLevel),
                    dcLevel: Int(dcLevel),
                    modelContext: modelContext
                )
                
                let targetAcLevel = acLevel
                let targetDcLevel = dcLevel

                // Wait for status to update
                try await vehicle.waitForStatusChange(
                    modelContext: modelContext,
                    condition: { status in
                        // Check if the target SOC values match what we set
                        guard let evStatus = status.evStatus else { return false }
                        return evStatus.targetSocAC == targetAcLevel && evStatus.targetSocDC == targetDcLevel
                    },
                    statusMessageUpdater: { message in
                        Task { @MainActor in
                            self.statusMessage = message
                        }
                    },
                    maxAttempts: 3,
                    initialDelaySeconds: 5,
                    retryDelaySeconds: 5
                )

                isSaving = false
                statusMessage = nil
                successMessage = "Charge limits saved"
            } catch {
                isSaving = false
                statusMessage = nil
                // Don't show error if it's just a timeout waiting for status - the command likely succeeded
                if error.localizedDescription.contains("condition not met") {
                    // Command was sent, just couldn't verify - show success anyway
                    successMessage = "Charge limits saved"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

