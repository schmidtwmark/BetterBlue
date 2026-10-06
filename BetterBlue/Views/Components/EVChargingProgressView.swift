//
//  EVChargingProgressView.swift
//  BetterBlue
//
//  Shared view for EV charging progress display
//  Used by both the vehicle sheet and the Live Activity
//

import SwiftUI

/// Shared view for displaying EV charging progress
/// Used by PersistentVehicleSheet in the main app and VehicleActivityWidget for Live Activities
struct EVChargingProgressView: View {
    let icon: Image?
    let formattedRange: String
    let batteryPercentage: Int
    let isCharging: Bool
    let chargeSpeed: String?
    let chargeTimeRemaining: String?
    let targetSOC: Double?
    let showHeader: Bool
    /// Tint used for the actively-charging progress fill and the pulsing
    /// header icon. Callers pass the vehicle's customizable
    /// `chargingColor` so the bar matches the rest of the app's accents.
    let chargingColor: Color

    init(
        icon: Image? = nil,
        formattedRange: String = "",
        batteryPercentage: Int,
        isCharging: Bool,
        chargeSpeed: String?,
        chargeTimeRemaining: String?,
        targetSOC: Double?,
        showHeader: Bool = true,
        chargingColor: Color = .green
    ) {
        self.icon = icon
        self.formattedRange = formattedRange
        self.batteryPercentage = batteryPercentage
        self.isCharging = isCharging
        self.chargeSpeed = chargeSpeed
        self.chargeTimeRemaining = chargeTimeRemaining
        self.targetSOC = targetSOC
        self.showHeader = showHeader
        self.chargingColor = chargingColor
    }

    var body: some View {
        VStack(spacing: 12) {
            if showHeader {
                // Top row: Icon (optional), Range, and Battery percentage
                HStack(spacing: 12) {
                    if let icon {
                        icon
                            .font(.title2)
                            .foregroundColor(isCharging ? chargingColor : .primary)
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
            }

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
            let width = geometry.size.width
            // x of the charge-limit line, when a sub-100% limit is set.
            let limitX: CGFloat? = targetSOC.flatMap { $0 < 100 ? width * ($0 / 100.0) : nil }

            ZStack(alignment: .leading) {
                // Track, a hatch over the won't-fill region beyond the
                // limit, the masked rectangular fill, then the limit line.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 32)

                    if let limitX {
                        DiagonalHatch(spacing: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: max(0, width - limitX), height: 32)
                            .clipped()
                            .offset(x: limitX)
                    }

                    Rectangle()
                        .fill(chargingColor)
                        .frame(width: fillWidth(width), height: 32)

                    if let limitX {
                        ChargeLimitLine()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: 1, height: 32)
                            .offset(x: limitX - 0.5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Charge speed — left-aligned over the fill.
                if let speed = chargeSpeed {
                    Text(speed)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(.leading, 12)
                }

                // Time remaining — right-aligned to the limit line, or the
                // bar's right edge when there's no limit.
                if let timeRemaining = chargeTimeRemaining {
                    Text(timeRemaining)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(.trailing, 8)
                        .frame(width: limitX ?? width, alignment: .trailing)
                }
            }
        }
        .frame(height: 32)
    }

    /// Battery fill as a 0...1 fraction and its pixel width — used to
    /// keep the inline labels off the fill/gray boundary.
    private var fillFraction: Double { min(max(Double(batteryPercentage) / 100.0, 0), 1) }
    private func fillWidth(_ width: CGFloat) -> CGFloat { width * fillFraction }

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
