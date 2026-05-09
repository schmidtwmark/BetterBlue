//
//  VehicleInfoComponents.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleBasicInfoSection: View {
    let bbVehicle: BBVehicle
    @Binding var showingCopiedMessage: Bool

    var body: some View {
        Section("Basic Information") {
            HStack {
                Text("Original Name")
                Spacer()
                Text(bbVehicle.model)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Brand")
                Spacer()
                if let account = bbVehicle.account {
                    Text(account.brandEnum.displayName)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("VIN")
                Spacer()
                Text(bbVehicle.vin)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                copyVINToClipboard()
            }
            VehicleFuelTypeOverride(bbVehicle: bbVehicle)
        }
    }

    private func copyVINToClipboard() {
        UIPasteboard.general.string = bbVehicle.vin

        withAnimation(.easeInOut(duration: 0.3)) {
            showingCopiedMessage = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingCopiedMessage = false
            }
        }
    }
}

/// Per-vehicle "Customization" section: widget background + the five
/// accent colors users can override (primary, charging, lock, unlock,
/// start-climate). Each color row pushes a `ColorSelectionView`; the
/// row's trailing accessory previews the currently-resolved color.
struct VehicleCustomizationSection: View {
    @Bindable var bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @State private var showingResetConfirm = false

    private var hasAnyOverride: Bool {
        bbVehicle.primaryColorName != nil
            || bbVehicle.chargingColorName != nil
            || bbVehicle.lockColorName != nil
            || bbVehicle.unlockColorName != nil
            || bbVehicle.startClimateColorName != nil
    }

    private func resetAllColors() {
        bbVehicle.primaryColorName = nil
        bbVehicle.chargingColorName = nil
        bbVehicle.lockColorName = nil
        bbVehicle.unlockColorName = nil
        bbVehicle.startClimateColorName = nil
        do {
            try modelContext.save()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            BBLogger.error(.app, "VehicleCustomizationSection: failed to reset colors: \(error)")
        }
    }

    var body: some View {
        Section {
            // Widget background — kept here to consolidate all
            // per-vehicle visual customization in one place. Same
            // <preview> <name> ─── <value> ›  layout as the color rows
            // so the section reads as a single visual list.
            NavigationLink(destination: BackgroundSelectionView(bbVehicle: bbVehicle)) {
                HStack(spacing: 12) {
                    // Preview is a miniature widget tile: rounded square
                    // filled with the chosen gradient, matching the
                    // proportions used by the color-row previews.
                    RoundedRectangle(cornerRadius: 28 * (12.0 / 52.0))
                        .fill(LinearGradient(
                            gradient: Gradient(colors: bbVehicle.backgroundGradient),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing,
                        ))
                        .frame(width: 28, height: 28)
                    Text("Widget Background")
                    Spacer()
                    Text(BBVehicle.availableBackgrounds.first(
                        where: { $0.name == bbVehicle.backgroundColorName },
                    )?.displayName ?? "Default")
                        .foregroundColor(.secondary)
                }
            }

            colorRow(
                title: "Primary Color",
                selection: $bbVehicle.primaryColorName,
                defaultName: "blue",
                previewStyle: .mapMarker
            )

            colorRow(
                title: "Charging Color",
                selection: $bbVehicle.chargingColorName,
                defaultName: "green",
                previewStyle: .quickAction(symbol: "bolt.fill")
            )

            colorRow(
                title: "Lock Color",
                selection: $bbVehicle.lockColorName,
                defaultName: "red",
                previewStyle: .quickAction(symbol: "lock.fill")
            )

            colorRow(
                title: "Unlock Color",
                selection: $bbVehicle.unlockColorName,
                defaultName: "green",
                previewStyle: .quickAction(symbol: "lock.open.fill")
            )

            colorRow(
                title: "Climate Color",
                selection: $bbVehicle.startClimateColorName,
                defaultName: "blue",
                previewStyle: .quickAction(symbol: "fan")
            )
        } header: {
            HStack {
                Text("Customization")
                Spacer()
                // Header-level escape hatch — wipes every override at once.
                // Hidden when nothing is overridden so the header doesn't
                // shout at users who haven't customized anything yet.
                if hasAnyOverride {
                    Button("Reset") {
                        showingResetConfirm = true
                    }
                    .font(.caption)
                    .textCase(nil)
                    .confirmationDialog(
                        "Reset all customization colors to their defaults?",
                        isPresented: $showingResetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Reset Colors", role: .destructive) {
                            resetAllColors()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func colorRow(
        title: String,
        selection: Binding<String?>,
        defaultName: String,
        previewStyle: ColorPreviewStyle
    ) -> some View {
        let resolved = CustomColor.option(forName: selection.wrappedValue, default: defaultName)
        NavigationLink(
            destination: ColorSelectionView(
                title: title,
                selectedName: selection,
                defaultName: defaultName,
                previewStyle: previewStyle,
                onChange: {
                    do {
                        try modelContext.save()
                        // Widgets and Live Activities cache the previously
                        // resolved color in their timeline snapshots, so kick
                        // a reload now to pick up the new selection.
                        WidgetCenter.shared.reloadAllTimelines()
                    } catch {
                        BBLogger.error(.app, "VehicleCustomizationSection: failed to save \(title): \(error)")
                    }
                }
            )
        ) {
            // Layout: <preview> <label> ─── <color name> ›
            // The miniature acts as the row's leading icon so the user
            // immediately sees which control they're customizing.
            HStack(spacing: 12) {
                ColorPreviewView(color: resolved.color, style: previewStyle, size: 28)
                Text(title)
                Spacer()
                Text(resolved.displayName)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Plain vehicle-type selector. Reads the effective `fuelType` (which
/// is the override when pinned, otherwise the inferred value), and any
/// change pins it as an override. The "automatic vs override" detail
/// is intentionally hidden — from the user's perspective it's just
/// "what kind of car is this?".
struct VehicleFuelTypeOverride: View {
    @Bindable var bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext

    private static let allTypes: [FuelType] = [.gas, .electric, .phev]

    private static func label(for type: FuelType) -> String {
        switch type {
        case .gas: "Gas"
        case .electric: "Electric"
        case .phev: "Plug-in Hybrid"
        }
    }

    private var selection: Binding<FuelType> {
        Binding(
            get: { bbVehicle.fuelType },
            set: { newValue in
                bbVehicle.fuelTypeOverride = newValue
                // Clear off-axis ranges so the UI updates immediately;
                // updateStatus already gates writes on the effective
                // fuelType, but stale data set BEFORE the change
                // wouldn't disappear on its own.
                bbVehicle.normalizeRangesForCurrentFuelType()
                do {
                    try modelContext.save()
                    // Widgets/Live Activities cache range visibility,
                    // so reload timelines too.
                    WidgetCenter.shared.reloadAllTimelines()
                } catch {
                    BBLogger.error(.app, "VehicleFuelTypeOverrideSection: failed to save type: \(error)")
                }
            }
        )
    }

    var body: some View {
            Picker("Vehicle Type", selection: selection) {
                ForEach(Self.allTypes, id: \.self) { type in
                    Text(Self.label(for: type)).tag(type)
                }
            }
    }
}
