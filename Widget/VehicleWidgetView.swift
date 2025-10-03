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
            VehicleControlsWidget(vehicle: vehicle)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        gradient: Gradient(colors: vehicle.backgroundGradient),
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
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Link(destination: URL(string: "betterblue://vehicle/\(vehicle.vin)")!) {
            switch family {
            case .systemSmall:
                VehicleSmallWidget(vehicle: vehicle)
            default:
                VehicleMediumWidget(vehicle: vehicle)
            }
        }
    }
}

struct VehicleMediumWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        UnifiedVehicleWidget(vehicle: vehicle, isSmall: false)
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

struct VehicleSmallWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        UnifiedVehicleWidget(vehicle: vehicle, isSmall: true)
    }
}

// Unified widget components
struct UnifiedVehicleWidget: View {
    let vehicle: VehicleEntity
    let isSmall: Bool

    var body: some View {
        VStack(spacing: isSmall ? 0 : 8) {
            // Vehicle header
            VehicleHeaderView(vehicle: vehicle, isSmall: isSmall)

            // Action buttons
            VehicleButtonsView(vehicle: vehicle, isSmall: isSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, isSmall ? 0 : 16)
    }
}

struct VehicleHeaderView: View {
    let vehicle: VehicleEntity
    let isSmall: Bool

    private var textColor: Color {
        let backgroundColors = vehicle.backgroundGradient
        guard !backgroundColors.isEmpty else { return .primary }

        let primaryColor = backgroundColors[0]
        return isLightColor(primaryColor) ? .black : .white
    }

    private func isLightColor(_ color: Color) -> Bool {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        // Calculate perceived brightness using standard luminance formula
        let brightness = (red * 0.299) + (green * 0.587) + (blue * 0.114)
        return brightness > 0.5
    }

    var body: some View {
        HStack {
            Text(vehicle.displayName)
                .font(isSmall ? .caption : .headline)
                .fontWeight(.bold)
                .foregroundColor(textColor)
                .lineLimit(1)

            Spacer()

            if isSmall {
                if vehicle.displayName.count <= 9 {
                    // Small widget: only show range if name is 8 characters or less
                    Text(vehicle.rangeText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                }
            } else {
                // Medium widget: icon, range, dot, percentage
                HStack(spacing: 4) {
                    Image(systemName: vehicle.isElectric ? "bolt.fill" : "fuelpump.fill")
                        .foregroundColor(vehicle.isElectric ? .green : .orange)
                        .font(.caption)

                    Text(vehicle.rangeText)
                        .font(.caption)
                        .foregroundColor(textColor)
                        .lineLimit(1)

                    Text("•")
                        .font(.caption)
                        .foregroundColor(textColor.opacity(0.7))

                    if let percentage = vehicle.batteryPercentage {
                        Text("\(Int(percentage))%")
                            .font(.caption)
                            .foregroundColor(textColor)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isSmall ? 4 : 6)
        .cornerRadius(12)
        .padding(.bottom, isSmall ? 4 : 0)
    }
}

struct VehicleButtonData {
    let label: String
    let shortLabel: String
    let icon: String
    let color: Color
    let intent: () -> any AppIntent
}

struct VehicleButtonsView: View {
    let vehicle: VehicleEntity
    let isSmall: Bool

    var buttonData: [VehicleButtonData] {
        [
            VehicleButtonData(label: "Lock", shortLabel: "Lock", icon: "lock.fill", color: .red, intent: {
                let intent = LockVehicleIntent()
                intent.vehicle = vehicle
                return intent
            }),
            VehicleButtonData(label: "Unlock", shortLabel: "Unlock", icon: "lock.open.fill", color: .green, intent: {
                let intent = UnlockVehicleIntent()
                intent.vehicle = vehicle
                return intent
            }),
            VehicleButtonData(label: "Start Climate", shortLabel: "Start", icon: "fan", color: .blue, intent: {
                let intent = StartClimateIntent()
                intent.vehicle = vehicle
                return intent
            }),
            VehicleButtonData(label: "Stop Climate", shortLabel: "Stop", icon: "fan.slash", color: .gray, intent: {
                let intent = StopClimateIntent()
                intent.vehicle = vehicle
                return intent
            })
        ]
    }

    var body: some View {
        if isSmall {
            // Small widget: 2x2 grid
            LazyVGrid(columns: Array(repeating: GridItem(spacing: 4), count: 2), spacing: 4) {
                ForEach(Array(buttonData.enumerated()), id: \.offset) { _, data in
                    Button(intent: data.intent()) {
                        Label(data.shortLabel, systemImage: data.icon)
                    }
                    .buttonStyle(WidgetButtonStyle(backgroundColor: data.color))
                }
            }
            .labelStyle(.iconOnly)
            .font(.headline)
            .fontWeight(.medium)
        } else {
            // Medium widget: 2x2 layout with full labels
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(buttonData.prefix(2).enumerated()), id: \.offset) { _, data in
                        Button(intent: data.intent()) {
                            Label(data.label, systemImage: data.icon)
                        }
                        .buttonStyle(WidgetButtonStyle(backgroundColor: data.color))
                    }
                }

                HStack(spacing: 6) {
                    ForEach(Array(buttonData.suffix(2).enumerated()), id: \.offset) { _, data in
                        Button(intent: data.intent()) {
                            Label(data.label, systemImage: data.icon)
                        }
                        .buttonStyle(WidgetButtonStyle(backgroundColor: data.color))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .font(.caption)
            .fontWeight(.medium)
        }
    }
}

#Preview(as: .systemMedium) {
    BetterBlueWidget()
} timeline: {
    let placeholderVehicle = VehicleEntity(
        id: "test",
        displayName: "Ioniq 5",
        vin: "test",
        isElectric: true,
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
        id: "test",
        displayName: "Genesis GV60",
        vin: "test",
        isElectric: true,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white",
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}

struct LockScreenVehicleWidgetView: View {
    let entry: VehicleWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let vehicle = entry.vehicle {
            switch family {
            case .accessoryCircular:
                LockScreenRangeWidget(vehicle: vehicle)
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

struct LockScreenProgressIcon: View {
    let vehicle: VehicleEntity
    let lineWidth = 3.0

    private var rangePercentage: Double {
        guard let batteryPercentage = vehicle.batteryPercentage else { return 0.0 }
        return batteryPercentage / 100.0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: rangePercentage)
                .stroke(Color.primary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 1), value: rangePercentage)

            Image(systemName: vehicle.isElectric ? "bolt.car.fill" : "car.fill")
        }
        .frame(width: 44, height: 44)
    }
}

struct LockScreenRangeWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        LockScreenProgressIcon(
            vehicle: vehicle,
        )
    }
}

struct LockScreenWideRangeWidget: View {
    let vehicle: VehicleEntity

    var body: some View {
        HStack(spacing: 8) {
            // Progress icon on the left
            LockScreenProgressIcon(
                vehicle: vehicle,
            )

            // Vehicle name and range text
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
        id: "test",
        displayName: "Model Y",
        vin: "test",
        isElectric: true,
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
        id: "test",
        displayName: "Ioniq 5",
        vin: "test",
        isElectric: true,
        rangeText: "250 mi",
        batteryPercentage: 85.0,
        timestamp: Date(),
        backgroundColorName: "white"
    )

    VehicleWidgetEntry(date: .now, vehicle: placeholderVehicle, configuration: VehicleWidgetIntent())
}
