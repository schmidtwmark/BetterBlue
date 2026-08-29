//
//  SurroundViewSettingsInfo.swift
//  BetterBlue
//
//  Info button + explanation sheet for the Surround View visibility
//  setting, mirroring `ClimateSettingsInfoButton` / `ClimateSettingsInfoSheet`
//  so the conditional settings in Vehicle Info all behave the same.
//

import SwiftUI

struct SurroundViewSettingsInfoButton: View {
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
        }
        .buttonStyle(.plain)
        // `textCase(nil)` so SwiftUI doesn't try to uppercase the
        // SF Symbol when it lives inside a Form section header.
        .textCase(nil)
        .sheet(isPresented: $showingInfo) {
            SurroundViewSettingsInfoSheet()
        }
    }
}

/// Explains what Surround View is and what each visibility choice does.
struct SurroundViewSettingsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingDescription(
                        title: "Surround View",
                        body: "Surround View shows the 360° camera images your vehicle " +
                            "captures and uploads on request. It's available on newer " +
                            "vehicles equipped with the cameras — the same ones that offer " +
                            "it in the MyHyundai / Kia Connect app."
                    )

                    settingDescription(
                        title: "Automatic",
                        body: "Shows the Surround View menu when your vehicle's generation " +
                            "suggests it has the cameras (generation 3+) and hides it on " +
                            "older vehicles. Not every newer trim actually has the hardware, " +
                            "so use Always Show or Always Hide if the automatic guess is wrong."
                    )

                    settingDescription(
                        title: "Always Show / Always Hide",
                        body: "Force the Surround View menu on or off for this vehicle, " +
                            "regardless of the automatic guess."
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Surround View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func settingDescription(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
