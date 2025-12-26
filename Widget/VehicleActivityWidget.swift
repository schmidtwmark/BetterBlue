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
                    Image(systemName: iconName(for: context.state.activityType))
                        .foregroundColor(iconColor(for: context.state.activityType))
                        .font(.title2)
                        .padding(.leading, 8)
                        .symbolEffect(.pulse, isActive: context.state.activityType != .none)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let evStatus = context.state.status.evStatus {
                        Text("\(Int(evStatus.evRange.percentage))%")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.trailing, 8)
                    } else if let gasRange = context.state.status.gasRange {
                        Text("\(Int(gasRange.percentage))%")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.trailing, 8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Use the shared content view but hide the top row since it's in leading/trailing
                    VehicleActivityContentView(context: context, isLockScreen: false)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.activityType))
                    .foregroundColor(iconColor(for: context.state.activityType))
                    .font(.caption2)
            } compactTrailing: {
                if let evStatus = context.state.status.evStatus {
                    Text("\(Int(evStatus.evRange.percentage))%")
                        .font(.caption2)
                } else if let gasRange = context.state.status.gasRange {
                    Text("\(Int(gasRange.percentage))%")
                        .font(.caption2)
                }
            } minimal: {
                Image(systemName: iconName(for: context.state.activityType))
                    .foregroundColor(iconColor(for: context.state.activityType))
                    .font(.caption2)
            }
            .widgetURL(URL(string: "betterblue://vehicle/\(context.attributes.vin)"))
            .keylineTint(iconColor(for: context.state.activityType))
        }
    }
    
    func iconName(for type: LiveActivityType) -> String {
        switch type {
        case .charging: "bolt.car.fill"
        case .climate: "fan.fill"
        case .none: "car.fill"
        }
    }
    
    func iconColor(for type: LiveActivityType) -> Color {
        switch type {
        case .charging: .green
        case .climate: .blue
        case .none: .gray
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
                pluggedIn: true,
                evRange: VehicleStatus.FuelRange(
                    range: Distance(length: 200, units: .miles),
                    percentage: 65
                ),
                chargeTime: .seconds(3600)
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
                chargeTime: .seconds(1800)
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

struct VehicleActivityContentView: View {
    let context: ActivityViewContext<VehicleActivityAttributes>
    let isLockScreen: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Top Row: Name and Battery (Only on Lock Screen)
            if isLockScreen {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: context.state.activityType))
                            .foregroundColor(iconColor(for: context.state.activityType))
                            .font(.title2)
                            .symbolEffect(.pulse, isActive: context.state.activityType != .none)
                        
                        Text(context.attributes.vehicleName)
                            .font(.headline)
                    }
                    
                    Spacer()
                    
                    if let evStatus = context.state.status.evStatus {
                        Text("\(Int(evStatus.evRange.percentage))%")
                            .font(.headline)
                    } else if let gasRange = context.state.status.gasRange {
                        Text("\(Int(gasRange.percentage))%")
                            .font(.headline)
                    }
                }
            }
            
            // Progress Bar (if charging)
            if context.state.activityType == .charging, let evStatus = context.state.status.evStatus {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 12)
                        
                        Capsule()
                            .fill(Color.green)
                            .frame(width: geometry.size.width * (evStatus.evRange.percentage / 100.0), height: 12)
                    }
                }
                .frame(height: 12)
            }
            
            // Status Row
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.activityType.message(for: context.state.activityState))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if context.state.activityType == .charging {
                        if let speed = context.state.status.evStatus?.chargeSpeed {
                            Text(String(format: "%.1f kW", speed))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if context.state.activityType == .climate {
                        let temp = context.state.status.climateStatus.temperature
                        Text("Cabin: \(Int(temp.value))\(temp.units.symbol)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if let evStatus = context.state.status.evStatus {
                        Text(evStatus.evRange.range.units.format(evStatus.evRange.range.length, to: evStatus.evRange.range.units))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else if let gasRange = context.state.status.gasRange {
                        Text(gasRange.range.units.format(gasRange.range.length, to: gasRange.range.units))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if context.state.activityType == .charging {
                        if let duration = context.state.status.evStatus?.chargeTime {
                            let timeString = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                            Text("Ends in \(timeString)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            // Footer
            HStack {
                Text("Updated \(context.state.status.lastUpdated, style: .time)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(isLockScreen ? 16 : 0) // Padding only for lock screen, Dynamic Island handles its own
        .activityBackgroundTint(Color.black.opacity(0.8))
        .activitySystemActionForegroundColor(Color.white)
    }
    
    func iconName(for type: LiveActivityType) -> String {
        switch type {
        case .charging: "bolt.car.fill"
        case .climate: "fan.fill"
        case .none: "car.fill"
        }
    }
    
    func iconColor(for type: LiveActivityType) -> Color {
        switch type {
        case .charging: .green
        case .climate: .blue
        case .none: .gray
        }
    }
}
