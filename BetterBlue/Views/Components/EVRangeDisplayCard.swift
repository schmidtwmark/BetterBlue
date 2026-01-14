//
//  EVRangeDisplayCard.swift
//  BetterBlue
//
//  Display-only card for EV range and battery info
//

import BetterBlueKit
import SwiftUI

struct EVRangeDisplayCard: View {
    let evStatus: VehicleStatus.EVStatus
    @State private var appSettings = AppSettings.shared

    var formattedRange: String {
        guard evStatus.evRange.range.length > 0 else {
            return "--"
        }
        return evStatus.evRange.range.units.format(
            evStatus.evRange.range.length,
            to: appSettings.preferredDistanceUnit
        )
    }

    var batteryPercentage: Int {
        Int(evStatus.evRange.percentage)
    }

    var isCharging: Bool {
        evStatus.charging
    }

    var chargeSpeed: String? {
        guard isCharging, evStatus.chargeSpeed > 0 else {
            return nil
        }
        return String(format: "%.1f kW", evStatus.chargeSpeed)
    }

    var chargeTimeRemaining: String? {
        guard isCharging else {
            return nil
        }
        let duration = evStatus.chargeTime
        guard duration > .seconds(0) else {
            return nil
        }
        let formattedTime = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))

        // If there's a target SOC, append "to X%"
        if let targetSOC = evStatus.currentTargetSOC {
            return "\(formattedTime) to \(Int(targetSOC))%"
        }
        return formattedTime
    }

    var body: some View {
        VStack(spacing: 12) {
            // Top row: Range and Battery percentage
            HStack(spacing: 12) {
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
                // Thicker bar with text when charging
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
                            .symbolEffect(.pulse, isActive: true)

                        // Target SOC indicator (dashed line)
                        if let targetSOC = evStatus.currentTargetSOC {
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

                        // Time remaining - positioned to the right of target SOC indicator
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
                                width: evStatus.currentTargetSOC != nil
                                    ? geometry.size.width * ((evStatus.currentTargetSOC ?? 100) / 100.0)
                                    : geometry.size.width,
                                height: 32
                            )
                        }
                    }
                }
                .frame(height: 32)
            } else {
                // Thin bar when not charging
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
        .padding()
        .vehicleCardGlassEffect()
    }
}
