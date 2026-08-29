//
//  OptionalFeaturesSection.swift
//  BetterBlue
//
//  The "Optional Features" section of Vehicle Settings: the switches for
//  capabilities BetterBlue can't always tell a vehicle has.
//
//  These used to be two adjacent sections — "Surround View" and "Climate
//  Settings" — each with its own header and info button, which read as
//  more structure than the four rows between them justified. They answer
//  the same question, so they share one section and one explanation now.
//
//  Every switch here follows the same rule: it starts from what the
//  vehicle reports about itself, and flipping it pins the answer for good.
//  BetterBlue infers what a vehicle supports from what the API tells it,
//  and that inference is sometimes wrong in both directions — a trim
//  without the hardware, or a car whose generation is under-reported.
//

import BetterBlueKit
import SwiftData
import SwiftUI

// MARK: - Section

struct OptionalFeaturesSection: View {
    let bbVehicle: BBVehicle

    /// Climate's two switches are for vehicles whose generation makes
    /// their support ambiguous. Newer ones support both unconditionally,
    /// so showing switches there would invite people to break something
    /// that already works — which is why the old Climate Settings section
    /// was gated this way, and why the merge keeps the gate rather than
    /// quietly exposing the toggles to everyone.
    private var showsClimateToggles: Bool {
        bbVehicle.generation < 3
    }

    @MainActor
    private var showsSurroundViewToggle: Bool {
        bbVehicle.account?.supportsSurroundView == true
    }

    var body: some View {
        if showsSurroundViewToggle || showsClimateToggles {
            Section {
                if showsSurroundViewToggle {
                    SurroundViewToggle(bbVehicle: bbVehicle)
                }
                if showsClimateToggles {
                    ClimateSettingsToggles(bbVehicle: bbVehicle)
                }
            } header: {
                HStack {
                    Text("Optional Features")
                    Spacer()
                    OptionalFeaturesInfoButton(
                        includesSurroundView: showsSurroundViewToggle,
                        includesClimate: showsClimateToggles
                    )
                }
            }
        }
    }
}

// MARK: - Surround View

/// Reads the effective setting and writes the override — the same shape
/// as "Show Climate Duration", so the switch always reflects what the
/// vehicle would actually do.
///
/// This replaced a three-way Automatic / Always Show / Always Hide picker.
/// A consequence worth knowing: once flipped there is no way back to
/// "automatic", because a `Bool` has nowhere to put that third state. The
/// automatic answer is almost always right, and the same trade already
/// applies to every other switch in this section.
struct SurroundViewToggle: View {
    @Bindable var bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle("Surround View", isOn: Binding(
            get: { bbVehicle.surroundViewEnabled },
            set: { newValue in
                bbVehicle.surroundViewOverride = newValue
                try? modelContext.save()
            }
        ))
    }
}

// MARK: - Info button + sheet

/// Small `info.circle` button suited to a `Form` section header.
struct OptionalFeaturesInfoButton: View {
    var includesSurroundView: Bool
    var includesClimate: Bool

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
            OptionalFeaturesInfoSheet(
                includesSurroundView: includesSurroundView,
                includesClimate: includesClimate
            )
        }
    }
}

/// Explains only the switches actually on screen — describing a control
/// the reader can't see is worse than saying nothing.
struct OptionalFeaturesInfoSheet: View {
    var includesSurroundView: Bool
    var includesClimate: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingDescription(
                        title: "About these settings",
                        text: "BetterBlue works out what your vehicle supports from what "
                            + "the service reports about it. That guess is occasionally "
                            + "wrong either way, so each switch starts from the guess and "
                            + "stays wherever you put it."
                    )

                    if includesSurroundView {
                        SettingDescription(
                            title: "Surround View",
                            text: "Shows the 360° camera images your vehicle captures and "
                                + "uploads on request — the same ones the MyHyundai / Kia "
                                + "Connect app shows. It's on by default for newer vehicles "
                                + "(generation 3+), which are the ones likely to have the "
                                + "cameras. Turn it off if your vehicle doesn't."
                        )
                    }

                    if includesClimate {
                        SettingDescription(
                            title: "Seat Heat Controls",
                            text: "Seat heating and cooling controls are available for newer "
                                + "vehicles (generation 3+). If the MyHyundai / Kia Connect "
                                + "app supports enabling seat heat / cooling, BetterBlue "
                                + "should be able to set it as well."
                        )

                        SettingDescription(
                            title: "Show Climate Duration",
                            text: "Newer vehicles (generation 3+) support setting a duration "
                                + "for climate control. If the MyHyundai / Kia Connect app "
                                + "supports setting a climate duration, BetterBlue should be "
                                + "able to set it as well."
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Optional Features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shared

/// A titled paragraph in a settings explanation sheet. Shared so the
/// Optional Features and Climate Settings sheets can't drift apart.
struct SettingDescription: View {
    let title: String
    /// Named `text` rather than `body` — that name is taken by `View`.
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
