import ActivityKit
import AppIntents
import BetterBlueKit
import SwiftUI
import WidgetKit

struct VehicleActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VehicleActivityAttributes.self) { context in
            // Lock screen/banner UI
            VehicleActivityContentView(context: context, isLockScreen: true)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.activityType == .debug {
                        Image(systemName: "ant")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                            .padding(.leading, 8)
                    } else if context.state.activityType == .climate {
                        Image(systemName: context.state.climatePresetIcon ?? "fan")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                            .padding(.leading, 8)
                    } else {
                        Text(formattedRange(for: context.state.status))
                            .font(.headline)
                            .fontWeight(.semibold)
                            .padding(.leading, 8)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.activityType == .debug {
                        Text("#\(context.state.wakeupCount)")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .padding(.trailing, 8)
                    } else if context.state.activityType == .climate {
                        let temp = context.state.status.climateStatus.temperature
                        Text("\(Int(temp.value))\(temp.units.symbol)")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .padding(.trailing, 8)
                    } else {
                        Text("\(batteryPercentage(for: context.state.status))%")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .padding(.trailing, 8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DynamicIslandExpandedContentView(context: context)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            } compactLeading: {
                if context.state.activityType == .debug {
                    Image(systemName: "ant")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                } else if context.state.activityType == .climate {
                    Image(systemName: context.state.climatePresetIcon ?? "fan")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                } else {
                    Text(formattedRange(for: context.state.status))
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            } compactTrailing: {
                if context.state.activityType == .debug {
                    Text("#\(context.state.wakeupCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                } else if context.state.activityType == .climate {
                    let temp = context.state.status.climateStatus.temperature
                    Text("\(Int(temp.value))\(temp.units.symbol)")
                        .font(.caption2)
                        .fontWeight(.medium)
                } else {
                    Text("\(batteryPercentage(for: context.state.status))%")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            } minimal: {
                if context.state.activityType == .debug {
                    Image(systemName: "ant")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if context.state.activityType == .climate {
                    Image(systemName: context.state.climatePresetIcon ?? "fan")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else {
                    Text("\(batteryPercentage(for: context.state.status))%")
                        .font(.caption2)
                }
            }
            .widgetURL(URL(string: "betterblue://vehicle/\(context.attributes.vin)"))
            .keylineTint(.green)
        }
    }

    func formattedRange(for status: VehicleStatus) -> String {
        if let evStatus = status.evStatus, evStatus.evRange.range.length > 0 {
            return evStatus.evRange.range.units.format(evStatus.evRange.range.length, to: evStatus.evRange.range.units)
        } else if let gasRange = status.gasRange, gasRange.range.length > 0 {
            return gasRange.range.units.format(gasRange.range.length, to: gasRange.range.units)
        }
        return "--"
    }

    func batteryPercentage(for status: VehicleStatus) -> Int {
        if let evStatus = status.evStatus {
            return Int(evStatus.evRange.percentage)
        } else if let gasRange = status.gasRange {
            return Int(gasRange.percentage)
        }
        return 0
    }
}

/// Content view for Dynamic Island expanded region
struct DynamicIslandExpandedContentView: View {
    let context: ActivityViewContext<VehicleActivityAttributes>

    private var evStatus: VehicleStatus.EVStatus? {
        context.state.status.evStatus
    }

    private var batteryPercentage: Int {
        Int(evStatus?.evRange.percentage ?? 0)
    }

    private var chargeSpeed: String? {
        guard let evStatus, evStatus.chargeSpeed > 0 else { return nil }
        return String(format: "%.1f kW", evStatus.chargeSpeed)
    }

    private var chargeTimeRemaining: String? {
        guard let evStatus else { return nil }
        let duration = evStatus.chargeTime
        guard duration > .seconds(0) else { return nil }
        let formattedTime = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        if let targetSOC = evStatus.currentTargetSOC {
            return "\(formattedTime) to \(Int(targetSOC))%"
        }
        return formattedTime
    }

    var body: some View {
        VStack(spacing: 8) {
            // Progress bar for charging
            if context.state.activityType == .charging {
                chargingProgressBar
            }

            // Climate status
            if context.state.activityType == .climate {
                HStack {
                    if let presetName = context.state.climatePresetName {
                        Text("\(presetName) Climate Preset Active")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    } else {
                        Text(context.state.activityType.message(for: context.state.activityState))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }

            // Debug status
            if context.state.activityType == .debug {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Live Activity")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if let lastWakeup = context.state.lastWakeupTime {
                            Text("Last wakeup: \(lastWakeup, style: .time)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No wakeups yet")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            // Footer with refresh status and action buttons
            HStack {
                if context.state.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Refreshing...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(context.attributes.vehicleName) • Updated \(context.state.status.lastUpdated, style: .time)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Stop button (only for climate and debug, not charging)
                if context.state.activityType != .charging {
                    Button(intent: StopLiveActivityIntent(vin: context.attributes.vin, activityType: context.state.activityType)) {
                        Image(systemName: context.state.activityType == .climate ? "power" : "stop.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(context.state.isRefreshing)
                }
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
                if let targetSOC = evStatus?.currentTargetSOC {
                    Line()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
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
                        width: evStatus?.currentTargetSOC != nil
                            ? geometry.size.width * ((evStatus?.currentTargetSOC ?? 100) / 100.0)
                            : geometry.size.width,
                        height: 32
                    )
                }
            }
        }
        .frame(height: 32)
    }
}

#Preview("Charging", as: .content, using: VehicleActivityAttributes(vehicleName: "My Ioniq 5", vin: "VIN123", vehicleId: UUID())) {
    VehicleActivityWidget()
} contentStates: {
    VehicleActivityAttributes.ContentState(
        status: VehicleStatus(
            vin: "VIN123",
            gasRange: nil,
            evStatus: VehicleStatus.EVStatus(
                charging: true,
                chargeSpeed: 7.2,
                pluggedIn: true,
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 200, units: .miles),
                    percentage: 65
                ),
                chargeTime: .seconds(3600),
                targetSocAC: 80,
                targetSocDC: 80
            ),
            location: VehicleStatus.Location(latitude: 0, longitude: 0),
            lockStatus: .locked,
            climateStatus: VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: false,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: 1, value: "72")
            ),
            odometer: Distance(length: 10000, units: .miles),
            syncDate: Date()
        ),
        activityType: .charging
    )
}

#Preview("Climate", as: .content, using: VehicleActivityAttributes(vehicleName: "My EV6", vin: "VIN456", vehicleId: UUID())) {
    VehicleActivityWidget()
} contentStates: {
    VehicleActivityAttributes.ContentState(
        status: VehicleStatus(
            vin: "VIN456",
            gasRange: nil,
            evStatus: VehicleStatus.EVStatus(
                charging: false,
                chargeSpeed: 0,
                pluggedIn: false,
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 250, units: .miles),
                    percentage: 80
                ),
                chargeTime: .seconds(0)
            ),
            location: VehicleStatus.Location(latitude: 0, longitude: 0),
            lockStatus: .locked,
            climateStatus: VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: true,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: 1, value: "70")
            ),
            odometer: Distance(length: 5000, units: .miles),
            syncDate: Date()
        ),
        activityType: .climate,
        climatePresetName: "Warm Up",
        climatePresetIcon: "sun.max"
    )
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: VehicleActivityAttributes(vehicleName: "My Ioniq 5", vin: "VIN123", vehicleId: UUID())) {
    VehicleActivityWidget()
} contentStates: {
    VehicleActivityAttributes.ContentState(
        status: VehicleStatus(
            vin: "VIN123",
            gasRange: nil,
            evStatus: VehicleStatus.EVStatus(
                charging: true,
                chargeSpeed: 150.0,
                pluggedIn: true,
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 120, units: .miles),
                    percentage: 45
                ),
                chargeTime: .seconds(1800),
                targetSocAC: 80,
                targetSocDC: 80
            ),
            location: VehicleStatus.Location(latitude: 0, longitude: 0),
            lockStatus: .locked,
            climateStatus: VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: false,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: 1, value: "72")
            ),
            odometer: Distance(length: 10000, units: .miles),
            syncDate: Date()
        ),
        activityType: .charging
    )
}

#Preview("Climate Dynamic Island", as: .dynamicIsland(.expanded), using: VehicleActivityAttributes(vehicleName: "My EV6", vin: "VIN456", vehicleId: UUID())) {
    VehicleActivityWidget()
} contentStates: {
    VehicleActivityAttributes.ContentState(
        status: VehicleStatus(
            vin: "VIN456",
            gasRange: nil,
            evStatus: VehicleStatus.EVStatus(
                charging: false,
                chargeSpeed: 0,
                pluggedIn: false,
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 250, units: .miles),
                    percentage: 80
                ),
                chargeTime: .seconds(0)
            ),
            location: VehicleStatus.Location(latitude: 0, longitude: 0),
            lockStatus: .locked,
            climateStatus: VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: true,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: 1, value: "70")
            ),
            odometer: Distance(length: 5000, units: .miles),
            syncDate: Date()
        ),
        activityType: .climate,
        climatePresetName: "Warm Up",
        climatePresetIcon: "sun.max"
    )
}

struct VehicleActivityContentView: View {
    let context: ActivityViewContext<VehicleActivityAttributes>
    let isLockScreen: Bool

    private var evStatus: VehicleStatus.EVStatus? {
        context.state.status.evStatus
    }

    private var batteryPercentage: Int {
        Int(evStatus?.evRange.percentage ?? 0)
    }

    private var chargeSpeed: String? {
        guard let evStatus, evStatus.chargeSpeed > 0 else { return nil }
        return String(format: "%.1f kW", evStatus.chargeSpeed)
    }

    private var chargeTimeRemaining: String? {
        guard let evStatus else { return nil }
        let duration = evStatus.chargeTime
        guard duration > .seconds(0) else { return nil }
        let formattedTime = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        if let targetSOC = evStatus.currentTargetSOC {
            return "\(formattedTime) to \(Int(targetSOC))%"
        }
        return formattedTime
    }

    private var formattedRange: String {
        guard let evStatus, evStatus.evRange.range.length > 0 else { return "--" }
        return evStatus.evRange.range.units.format(evStatus.evRange.range.length, to: evStatus.evRange.range.units)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Charging activity uses shared EVChargingProgressView (no icon for Live Activity)
            if context.state.activityType == .charging, isLockScreen {
                EVChargingProgressView(
                    formattedRange: formattedRange,
                    batteryPercentage: batteryPercentage,
                    isCharging: true,
                    chargeSpeed: chargeSpeed,
                    chargeTimeRemaining: chargeTimeRemaining,
                    targetSOC: evStatus?.currentTargetSOC
                )
            }

            // Climate status (if climate is running)
            if context.state.activityType == .climate, isLockScreen {
                HStack(spacing: 12) {
                    Image(systemName: context.state.climatePresetIcon ?? "fan")
                        .font(.title2)
                        .foregroundColor(.blue)

                    if let presetName = context.state.climatePresetName {
                        Text("\(presetName) Climate Preset Active")
                            .font(.headline)
                            .fontWeight(.semibold)
                    } else {
                        Text(context.state.activityType.message(for: context.state.activityState))
                            .font(.headline)
                            .fontWeight(.semibold)
                    }

                    Spacer()

                    let temp = context.state.status.climateStatus.temperature
                    Text("\(Int(temp.value))\(temp.units.symbol)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }

            // Debug status (if debug is running)
            if context.state.activityType == .debug, isLockScreen {
                HStack(spacing: 12) {
                    Image(systemName: "ant")
                        .font(.title2)
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Live Activity")
                            .font(.headline)
                            .fontWeight(.semibold)
                        if let lastWakeup = context.state.lastWakeupTime {
                            Text("Last wakeup: \(lastWakeup, style: .time)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Waiting for wakeup...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Text("#\(context.state.wakeupCount)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
            }

            // Footer with action buttons
            HStack {
                if context.state.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Refreshing...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(context.attributes.vehicleName) • Updated \(context.state.status.lastUpdated, style: .time)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Stop button (only for climate and debug, not charging)
                if context.state.activityType != .charging {
                    Button(intent: StopLiveActivityIntent(vin: context.attributes.vin, activityType: context.state.activityType)) {
                        HStack(spacing: 4) {
                            Image(systemName: context.state.activityType == .climate ? "power" : "stop.fill")
                            Text("Stop")
                        }
                        .font(.caption2)
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(context.state.isRefreshing)
                }
            }
        }
        .padding(isLockScreen ? 16 : 0)
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(Color.white)
    }
}
