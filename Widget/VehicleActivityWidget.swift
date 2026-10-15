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
                            .foregroundColor(CustomColor.color(
                                forName: context.attributes.startClimateColorName,
                                default: "blue"
                            ))
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
                    } else if context.state.activityType == .climate,
                              context.state.status.climateStatus.temperature.isPlausibleForDisplay {
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
                        .foregroundColor(CustomColor.color(
                            forName: context.attributes.startClimateColorName,
                            default: "blue"
                        ))
                } else {
                    CompactIslandText(
                        text: formattedRange(for: context.state.status),
                        limitedWidthText: formattedRange(for: context.state.status, includesUnit: false),
                        cameraEdge: .trailing
                    )
                }
            } compactTrailing: {
                if context.state.activityType == .debug {
                    CompactIslandText(text: "#\(context.state.wakeupCount)", cameraEdge: .leading)
                } else if context.state.activityType == .climate,
                          context.state.status.climateStatus.temperature.isPlausibleForDisplay {
                    let temp = context.state.status.climateStatus.temperature
                    CompactIslandText(text: "\(Int(temp.value))\(temp.units.symbol)", cameraEdge: .leading)
                } else {
                    CompactIslandText(text: "\(batteryPercentage(for: context.state.status))%", cameraEdge: .leading)
                }
            } minimal: {
                if context.state.activityType == .debug {
                    Image(systemName: "ant")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if context.state.activityType == .climate {
                    Image(systemName: context.state.climatePresetIcon ?? "fan")
                        .font(.caption2)
                        .foregroundColor(CustomColor.color(
                            forName: context.attributes.startClimateColorName,
                            default: "blue"
                        ))
                } else {
                    Text("\(batteryPercentage(for: context.state.status))%")
                        .font(.caption2)
                        .compactIslandText()
                }
            }
            .widgetURL(URL(string: "betterblue://vehicle/\(context.attributes.vin)"))
            .keylineTint(.green)
        }
    }

    func formattedRange(for status: VehicleStatus, includesUnit: Bool = true) -> String {
        let range: Distance
        if let evStatus = status.evStatus, evStatus.evRange.range.length > 0 {
            range = evStatus.evRange.range
        } else if let gasRange = status.gasRange, gasRange.range.length > 0 {
            range = gasRange.range
        } else {
            return "--"
        }
        let preferredUnit = AppSettings.liveDistanceUnit()
        guard includesUnit else {
            return range.units.convert(range.length, to: preferredUnit)
                .formatted(.number.precision(.fractionLength(0)))
        }
        return range.units.format(range.length, to: preferredUnit)
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

private extension Text {
    /// Compact/minimal Dynamic Island slots can be narrower than the text.
    /// Keep it on one line and shrink instead of wrapping ("329\nmi").
    func compactIslandText() -> some View {
        self
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

/// Text for a compact leading/trailing Dynamic Island slot.
///
/// When iOS 27 shares the island between activities
/// (`isDynamicIslandLimitedInWidth`), it stops sizing the slots to their
/// content: each gets a fixed 28 pt square with the content centered in it.
/// With three activities on iPhone 18 Pro those squares straddle the camera,
/// which hides about 5 pt of each one's inner side — "82%" read "32%" and
/// "255 mi" read "255 m" (#110). There, keep the text clear of the camera
/// and use the shorter text if there is one.
private struct CompactIslandText: View {
    let text: String
    /// Shown instead of `text` in a limited-width island, e.g. the range
    /// without its unit, which would otherwise shrink to half size.
    var limitedWidthText: String?
    /// The slot's side facing the camera: trailing for compact leading,
    /// leading for compact trailing.
    let cameraEdge: HorizontalEdge

    /// Covers the camera's overlap with a limited-width slot (4.3–5.7 pt).
    private static let cameraClearance: CGFloat = 7

    var body: some View {
        if #available(iOS 27.0, *) {
            LimitedWidthReader { isLimited in label(isLimited: isLimited) }
        } else {
            label(isLimited: false)
        }
    }

    private func label(isLimited: Bool) -> some View {
        Text(isLimited ? limitedWidthText ?? text : text)
            .font(.caption2)
            .fontWeight(.medium)
            .compactIslandText()
            .padding(cameraEdge == .leading ? .leading : .trailing, isLimited ? Self.cameraClearance : 0)
    }
}

@available(iOS 27.0, *)
private struct LimitedWidthReader<Content: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited
    @ViewBuilder let content: (_ isLimited: Bool) -> Content

    var body: some View {
        content(isLimited)
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
                EVChargingProgressView(
                    batteryPercentage: batteryPercentage,
                    isCharging: true,
                    chargeSpeed: chargeSpeed,
                    chargeTimeRemaining: chargeTimeRemaining,
                    targetSOC: evStatus?.currentTargetSOC,
                    showHeader: false,
                    chargingColor: CustomColor.color(
                        forName: context.attributes.chargingColorName,
                        default: "green"
                    )
                )
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

            // Footer with refresh status and action buttons.
            // Vehicle name + "Updated …" both use caption2/secondary
            // so the footer reads as a single understated metadata
            // row instead of the name dominating the card. The lone
            // Spacer between name and time pushes the time all the
            // way to the trailing edge (or just inside the stop
            // button when one is present).
            HStack {
                if context.state.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Refreshing...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Text(context.attributes.vehicleName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Updated \(context.state.status.lastUpdated, style: .time)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Stop button (only for climate and debug, not charging)
                if context.state.activityType != .charging {
                    Button(intent: StopLiveActivityIntent(vin: context.attributes.vin, activityType: context.state.activityType)) {
                        Image(systemName: context.state.activityType == .climate ? "power" : "stop.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(context.state.isRefreshing)
                    .padding(.leading, 8)
                }
            }
        }
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
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 200, units: .miles),
                    percentage: 65
                ),
                plugType: .acCharger,
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
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 250, units: .miles),
                    percentage: 80
                ),
                plugType: .unplugged,
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
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 120, units: .miles),
                    percentage: 45
                ),
                plugType: .dcCharger,
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
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 250, units: .miles),
                    percentage: 80
                ),
                plugType: .unplugged,
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
        return evStatus.evRange.range.units.format(evStatus.evRange.range.length, to: AppSettings.liveDistanceUnit())
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
                    targetSOC: evStatus?.currentTargetSOC,
                    chargingColor: CustomColor.color(
                        forName: context.attributes.chargingColorName,
                        default: "green"
                    )
                )
            }

            // Climate status (if climate is running)
            if context.state.activityType == .climate, isLockScreen {
                HStack(spacing: 12) {
                    Image(systemName: context.state.climatePresetIcon ?? "fan")
                        .font(.title2)
                        .foregroundColor(CustomColor.color(
                            forName: context.attributes.startClimateColorName,
                            default: "blue"
                        ))

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

                    if context.state.status.climateStatus.temperature.isPlausibleForDisplay {
                        let temp = context.state.status.climateStatus.temperature
                        Text("\(Int(temp.value))\(temp.units.symbol)")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
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

            // Footer with action buttons. Vehicle name leads, time
            // pushed to the trailing edge — same treatment as the
            // content-card footer above so the two layouts read
            // consistently.
            HStack {
                if context.state.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Refreshing...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    Text(context.attributes.vehicleName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Updated \(context.state.status.lastUpdated, style: .time)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

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
                    .padding(.leading, 8)
                }
            }
        }
        .padding(isLockScreen ? 16 : 0)
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(Color.white)
    }
}
