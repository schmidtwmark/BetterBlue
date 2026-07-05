//
//  VehicleWidgetView.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftUI
import WidgetKit

struct VehicleWidgetEntryView: View {
    let entry: VehicleWidgetEntry

    var body: some View {
        if let vehicle = entry.vehicle {
            // The background (and its matching text color) are resolved
            // here. "Default" uses dynamic colors so it swaps with the
            // system appearance at the render layer — no colorScheme env.
            let style = WidgetBackground.style(
                forName: entry.configuration.effectiveBackgroundName(for: vehicle)
            )
            VehicleControlsWidget(
                vehicle: vehicle,
                buttons: entry.configuration.slotButtons,
                textColor: style.textColor,
                showEVPercent: entry.configuration.showEVPercentage,
                showGasPercent: entry.configuration.showGasPercentage
            )
            .containerBackground(for: .widget) {
                LinearGradient(
                    gradient: Gradient(colors: style.gradient),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            VStack {
                Image(systemName: "car.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No Vehicle")
                    .font(.headline)
                Text("Add an account in the app")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .containerBackground(for: .widget) {
                Color(.systemBackground)
            }
        }
    }
}

struct VehicleControlsWidget: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let textColor: Color
    let showEVPercent: Bool
    let showGasPercent: Bool
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Link(destination: URL(string: "betterblue://vehicle/\(vehicle.vin)")!) {
            UnifiedVehicleWidget(
                vehicle: vehicle,
                buttons: buttons,
                textColor: textColor,
                showEVPercent: showEVPercent,
                showGasPercent: showGasPercent,
                isSmall: family == .systemSmall
            )
        }
    }
}

struct WidgetButtonStyle: ButtonStyle {
    let backgroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor.opacity(0.6))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Unified widget components
struct UnifiedVehicleWidget: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let textColor: Color
    let showEVPercent: Bool
    let showGasPercent: Bool
    let isSmall: Bool

    var body: some View {
        VStack(spacing: isSmall ? 6 : 8) {
            // Vehicle header
            VehicleHeaderView(
                vehicle: vehicle, textColor: textColor,
                showEVPercent: showEVPercent, showGasPercent: showGasPercent, isSmall: isSmall
            )

            // Action buttons
            VehicleButtonsView(vehicle: vehicle, buttons: buttons, isSmall: isSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, isSmall ? 6 : 16)
    }
}

/// Resolves a background catalog name to its gradient + matching text
/// color. "default" is adaptive: built from dynamic `UIColor`s so it
/// swaps with the system appearance at the render layer — instantly,
/// like stock widgets, rather than waiting on a timeline reload. Light
/// mode uses `systemBackground` (matching the stock light widget
/// surface); dark mode uses the dark-glass gradient. Text is
/// `Color.label` so it flips black/white with the surface.
enum WidgetBackground {
    static func style(forName name: String) -> (gradient: [Color], textColor: Color) {
        if name == "default" {
            return (adaptiveDefaultGradient, Color(uiColor: .label))
        }
        let gradient = BBVehicle.availableBackgrounds.first { $0.name == name }?.gradient
            ?? BBVehicle.availableBackgrounds[0].gradient
        return (gradient, isLight(gradient.first) ? .black : .white)
    }

    private static let adaptiveDefaultGradient: [Color] = [
        dynamicSurface(darkRed: 0.11, darkGreen: 0.11, darkBlue: 0.12),
        dynamicSurface(darkRed: 0.17, darkGreen: 0.17, darkBlue: 0.18)
    ]

    private static func dynamicSurface(darkRed: CGFloat, darkGreen: CGFloat, darkBlue: CGFloat) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: darkRed, green: darkGreen, blue: darkBlue, alpha: 1)
                : .systemBackground
        })
    }

    private static func isLight(_ color: Color?) -> Bool {
        guard let color else { return false }
        let uiColor = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red * 0.299 + green * 0.587 + blue * 0.114) > 0.5
    }
}

struct VehicleHeaderView: View {
    let vehicle: VehicleEntity
    /// Resolved by `WidgetBackground` to match the background — a fixed
    /// black/white for solid backgrounds, or dynamic `Color.label` for
    /// the adaptive Default.
    let textColor: Color
    let showEVPercent: Bool
    let showGasPercent: Bool
    let isSmall: Bool

    private var statusData: StatusSectionData {
        StatusSectionData(vehicle, showEVPercent: showEVPercent, showGasPercent: showGasPercent)
    }

    var body: some View {
        Group {
            if isSmall {
                smallHeader
            } else {
                mediumHeader
            }
        }
        .padding(.horizontal, isSmall ? 0 : 8)
        .padding(.vertical, isSmall ? 0 : 6)
        .padding(.bottom, isSmall ? 2 : 0)
    }

    /// 2×2: name on top, then a single status line that leads with the
    /// time and continues with the ranges + lock/climate glyphs, with
    /// the percentage bars beneath — all centered, full width.
    private var smallHeader: some View {
        VStack(alignment: .center, spacing: 3) {
            Text(vehicle.displayName)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            VehicleStatusColumn(
                data: statusData, textColor: textColor, isSmall: true, leadingTime: absoluteUpdated
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 4×2: name + time on the left; all status on the right, vertically
    /// centered against the title block.
    private var mediumHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(vehicle.displayName)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                subtitleLine
                    .font(.caption2)
                    .foregroundColor(textColor.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            VehicleStatusColumn(data: statusData, textColor: textColor, isSmall: false)
                .frame(maxWidth: 196, alignment: .trailing)
        }
    }

    /// The line under the title. Normally the absolute last-updated
    /// time (the lock/climate glyphs now live in the status column on
    /// the right). When the user has just tapped a widget button, it's
    /// replaced by "<command> requested at <time>" until a real status
    /// refresh lands. Absolute (not relative) time because a widget's
    /// text is frozen between timeline reloads — a relative "5m ago"
    /// would silently go stale.
    @ViewBuilder
    private var subtitleLine: some View {
        if let pending = pendingCommand {
            Text("\(pending.command) requested at \(absoluteTime(pending.date))")
        } else {
            Text(absoluteUpdated)
        }
    }

    /// The most recent widget-button command for this vehicle, but only
    /// while it's still "pending" — newer than the last status refresh
    /// and recent enough to be relevant (a real refresh that postdates
    /// it means the status now reflects reality, so we stop showing it).
    private var pendingCommand: (command: String, date: Date)? {
        guard let latest = WidgetCommandStatus.latest(vin: vehicle.vin) else { return nil }
        let lastUpdated = vehicle.lastUpdated ?? .distantPast
        guard latest.date > lastUpdated,
              Date().timeIntervalSince(latest.date) < 30 * 60 else { return nil }
        return latest
    }

    private var absoluteUpdated: String {
        let date = vehicle.timestamp
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func absoluteTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension StatusSectionData {
    /// Projects a widget `VehicleEntity` into the plain inputs the
    /// shared status section renders.
    init(_ vehicle: VehicleEntity, showEVPercent: Bool = true, showGasPercent: Bool = true) {
        self.init(
            hasElectricCapability: vehicle.fuelType.hasElectricCapability,
            evRange: vehicle.evRange,
            evBatteryPercentage: vehicle.evBatteryPercentage,
            gasRange: vehicle.gasRange,
            gasFuelPercentage: vehicle.gasFuelPercentage,
            rangeText: vehicle.rangeText,
            batteryPercentage: vehicle.batteryPercentage,
            isCharging: vehicle.isCharging ?? false,
            chargeSpeedKilowatts: vehicle.chargeSpeedKilowatts,
            chargeTimeRemainingMinutes: vehicle.chargeTimeRemainingMinutes,
            targetStateOfCharge: vehicle.targetStateOfCharge,
            isLocked: vehicle.isLocked,
            isClimateOn: vehicle.isClimateOn,
            chargingColor: vehicle.chargingColor,
            gasColor: vehicle.gasColor,
            showEVPercent: showEVPercent,
            showGasPercent: showGasPercent
        )
    }
}

extension WidgetActionEntity {
    /// Maps a configured action onto its concrete control intent,
    /// targeting the widget's vehicle (or, for a preset-specific
    /// action, the preset's own vehicle). Lives here — not next to the
    /// entity — because the control intents are iOS-only while the
    /// entity is shared with the watch widget target.
    func makeIntent(for vehicle: VehicleEntity) -> (any AppIntent)? {
        switch kind {
        case .lock:
            let intent = LockVehicleControlIntent()
            intent.vehicle = vehicle
            return intent
        case .unlock:
            let intent = UnlockVehicleControlIntent()
            intent.vehicle = vehicle
            return intent
        case .stopClimate:
            let intent = StopClimateControlIntent()
            intent.vehicle = vehicle
            return intent
        case .startCharge:
            let intent = StartChargeControlIntent()
            intent.vehicle = vehicle
            return intent
        case .stopCharge:
            let intent = StopChargeControlIntent()
            intent.vehicle = vehicle
            return intent
        case .startClimate:
            let intent = StartClimateControlIntent()
            if let presetId, let presetVin {
                intent.preset = ClimatePresetEntity(
                    id: presetId,
                    vehicleVin: presetVin,
                    vehicleName: presetVehicleName ?? vehicle.displayName,
                    presetName: presetName ?? "Climate",
                    presetIcon: presetIcon ?? "fan",
                    isSelected: false
                )
            } else {
                intent.preset = vehicle.selectedPreset
            }
            return intent
        case .none:
            return nil
        }
    }

    /// Icon to render on the button. A preset-specific start-climate
    /// action carries the preset's own icon; the generic "Start
    /// Climate" resolves to the vehicle's selected-preset icon so the
    /// button matches what it'll actually run.
    func displayIcon(for vehicle: VehicleEntity) -> String {
        if kind == .startClimate, presetId == nil {
            return vehicle.selectedPreset?.presetIcon ?? iconName
        }
        return iconName
    }
}

struct VehicleButtonsView: View {
    let vehicle: VehicleEntity
    let buttons: [ConfiguredWidgetButton]
    let isSmall: Bool

    var body: some View {
        if isSmall {
            // Small widget: 2-column grid, icons only
            LazyVGrid(columns: Array(repeating: GridItem(spacing: 4), count: 2), spacing: 4) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    actionButton(button)
                }
            }
            .labelStyle(.iconOnly)
            .font(.headline)
            .fontWeight(.medium)
        } else {
            // Medium widget: rows of two with full labels
            VStack(spacing: 8) {
                ForEach(Array(buttons.chunked(into: 2).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, button in
                            actionButton(button)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .font(.caption)
            .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func actionButton(_ button: ConfiguredWidgetButton) -> some View {
        if let intent = button.action.makeIntent(for: vehicle) {
            Button(intent: intent) {
                Label(button.action.kind.defaultTitle, systemImage: button.action.displayIcon(for: vehicle))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(WidgetButtonStyle(backgroundColor: button.color(for: vehicle)))
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

#Preview(as: .systemMedium) {
    BetterBlueWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Ioniq 5",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white",
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

#Preview(as: .systemSmall) {
    BetterBlueWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Genesis GV60",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white",
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

struct LockScreenVehicleWidgetView: View {
    let entry: VehicleWidgetEntry
    /// What the circular ring shows in its center — the percentage
    /// widget and the range widget share this one view.
    var circularCenter: VehicleRingGauge.Center = .percentage
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let vehicle = entry.vehicle {
            switch family {
            case .accessoryCircular:
                LockScreenRangeWidget(vehicle: vehicle, center: circularCenter)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            case .accessoryRectangular:
                LockScreenWideRangeWidget(vehicle: vehicle)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            default:
                LockScreenRangeWidget(vehicle: vehicle)
                    .containerBackground(for: .widget) {
                        Color.clear
                    }
            }
        } else {
            Image(systemName: "car.fill")
                .foregroundColor(.secondary)
                .font(.title2)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
    }
}

/// Battery-widget-style ring: the SYSTEM accessoryCircular gauge (270°
/// arc with a bottom gap and rounded caps — the exact rendering Apple's
/// Batteries lock-screen widget uses, unlike the old hand-drawn full
/// circle), with the fuel glyph in the gap and a configurable center.
struct VehicleRingGauge: View {
    enum Center { case percentage, range }
    let vehicle: VehicleEntity
    let center: Center

    private var percentage: Double { vehicle.batteryPercentage ?? 0 }

    /// "203 mi" → ("203", "mi") so the unit can render small under the
    /// number inside the ring; non-splittable text passes through whole.
    private var rangeParts: (String, String?) {
        let parts = vehicle.rangeText.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (vehicle.rangeText, nil) }
        return (String(parts[0]), String(parts[1]))
    }

    var body: some View {
        Gauge(value: percentage, in: 0 ... 100) {
            Image(systemName: vehicle.fuelType.hasElectricCapability ? "bolt.fill" : "fuelpump.fill")
        } currentValueLabel: {
            switch center {
            case .percentage:
                // Bare number, matching Apple's battery ring.
                Text("\(Int(percentage.rounded()))")
            case .range:
                let (value, unit) = rangeParts
                VStack(spacing: -2) {
                    Text(value)
                        .minimumScaleFactor(0.5)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }
}

struct LockScreenRangeWidget: View {
    let vehicle: VehicleEntity
    var center: VehicleRingGauge.Center = .percentage

    var body: some View {
        VehicleRingGauge(vehicle: vehicle, center: center)
    }
}

struct LockScreenWideRangeWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        HStack(spacing: 10) {
            // Percentage ring on the left, name + range beside it.
            VehicleRingGauge(vehicle: vehicle, center: .percentage)

            VStack(alignment: .leading, spacing: 1) {
                Text(vehicle.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(vehicle.rangeText)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .accessoryCircular) {
    BetterBlueLockScreenWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Model Y",
        vin: "test",
        fuelType: .electric,
        rangeText: "280 mi",
        batteryPercentage: 75.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

#Preview(as: .accessoryRectangular) {
    BetterBlueLockScreenWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Ioniq 5",
        vin: "test",
        fuelType: .electric,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

#Preview(as: .accessoryCircular) {
    BetterBlueLockScreenRangeWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: .init(),
        displayName: "Model Y",
        vin: "test",
        fuelType: .electric,
        rangeText: "280 mi",
        batteryPercentage: 75.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}
