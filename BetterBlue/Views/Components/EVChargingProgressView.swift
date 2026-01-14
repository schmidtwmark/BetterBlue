//
//  EVChargingProgressView.swift
//  BetterBlue
//
//  Shared view for EV charging progress display
//  Used by both EVRangeChargingCard and Live Activity
//

import SwiftUI

/// Shared view for displaying EV charging progress
/// Used by EVRangeChargingCard in the main app and VehicleActivityWidget for Live Activities
struct EVChargingProgressView: View {
    let icon: Image?
    let formattedRange: String
    let batteryPercentage: Int
    let isCharging: Bool
    let chargeSpeed: String?
    let chargeTimeRemaining: String?
    let targetSOC: Double?

    init(
        icon: Image? = nil,
        formattedRange: String,
        batteryPercentage: Int,
        isCharging: Bool,
        chargeSpeed: String?,
        chargeTimeRemaining: String?,
        targetSOC: Double?
    ) {
        self.icon = icon
        self.formattedRange = formattedRange
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.chargeSpeed = chargeSpeed
        self.chargeTimeRemaining = chargeTimeRemaining
        self.targetSOC = targetSOC
    }

    var body: some View {
        VStack(spacing: 12) {
            // Top row: Icon (optional), Range, and Battery percentage
            HStack(spacing: 12) {
                if let icon {
                    icon
                        .font(.title2)
                        .foregroundColor(isCharging ? .green : .primary)
                        .symbolEffect(.pulse, isActive: isCharging)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("EV Range")
                        .font(.caption)
                    Text(formattedRange)
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Battery")
                        .font(.caption)
                    Text("\(batteryPercentage)%")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
            .foregroundColor(.primary)

            // Progress bar
            if isCharging {
                chargingProgressBar
            } else {
                notChargingProgressBar
            }
        }
    }

    private var chargingProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 32)

                // Foreground progress
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green)
                    .frame(
                        width: geometry.size.width * (Double(batteryPercentage) / 100.0),
                        height: 32
                    )

                // Target SOC indicator (dashed line)
                if let targetSOC {
                    Line()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .foregroundColor(.white)
                        .frame(width: 2, height: 32)
                        .offset(x: geometry.size.width * (targetSOC / 100.0) - 1)
                }

                // Text overlay - charge speed on left
                HStack {
                    if let speed = chargeSpeed {
                        Text(speed)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.leading, 12)
                    }
                    Spacer()
                }
                .frame(height: 32)

                // Time remaining - positioned within target SOC area
                if let timeRemaining = chargeTimeRemaining {
                    HStack {
                        Spacer()
                        Text(timeRemaining)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.trailing, 12)
                    }
                    .frame(
                        width: targetSOC != nil
                            ? geometry.size.width * ((targetSOC ?? 100) / 100.0)
                            : geometry.size.width,
                        height: 32
                    )
                }
            }
        }
        .frame(height: 32)
    }

    private var notChargingProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)

                // Foreground
                Capsule()
                    .fill(Color.gray.opacity(0.5))
                    .frame(
                        width: geometry.size.width * (Double(batteryPercentage) / 100.0),
                        height: 6
                    )
            }
        }
        .frame(height: 6)
    }
}
