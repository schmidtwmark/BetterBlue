//
//  TripDetailsView.swift
//  BetterBlue
//
//  View for displaying EV trip details and efficiency chart
//

import BetterBlueKit
import Charts
import SwiftUI
import SwiftData

struct TripDetailsView: View {
    let bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @State private var trips: [EVTripSummary] = []
    @State private var isLoading = true
    @State private var loadError: ActionError?
    @State private var appSettings = AppSettings.shared
    @State private var showEnergyBreakdown = false
    /// Offset from current period.
    /// EU (weekly):  0 = this week, -1 = last week.
    /// Other (daily): 0 = today, -1 = yesterday.
    @State private var periodOffset: Int = 0
    @State private var detailedTrips: [Date: [EVTripInfo]] = [:]

    var body: some View {
        PersistentModelGuard(model: bbVehicle) {
            Group {
                if isLoading {
                    loadingView
                } else if let loadError {
                    errorView(loadError)
                } else if trips.isEmpty {
                    emptyView
                } else {
                    tripListView
                }
            }
            .navigationTitle("Trip History")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadTripDetails()
            }
            .onChange(of: periodOffset) { _, _ in
                Task {
                    await loadDetailedTripsForSelectedPeriod()
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading trip details...")
                .foregroundColor(.secondary)
        }
    }

    private func errorView(_ error: ActionError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)

            ErrorDetailsView(error: error)
                .padding(.horizontal)

            Button("Try Again") {
                Task {
                    await loadTripDetails()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Recent Trips")
                .font(.headline)
            Text("Trip history will appear here after you drive your vehicle.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var tripListView: some View {
        List {
            // Period navigator (week for EU daily summaries, day for others)
            Section {
                periodNavigatorView
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            // Energy usage chart section
            Section {
                energyUsageChartView
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            } header: {
                HStack {
                    Text("Energy Usage")
                    Spacer()
                    Toggle("Breakdown", isOn: $showEnergyBreakdown)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }

            // Trip list section
            Section {
                if tripsForSelectedPeriod.isEmpty {
                    Text(isDailySummaryData ? "No trips this week" : "No trips today")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(tripsForSelectedPeriod) { trip in
                        TripDetailRow(
                            trip: trip,
                            distanceUnit: appSettings.preferredDistanceUnit,
                            isDailySummary: isDailySummaryData,
                            bbVehicle: bbVehicle,
                            supportsTripInfo: supportsTripInfo,
                            detailedTrips: detailedTrips[trip.startDate]
                        )
                    }
                }
            } header: {
                Text("Recent Trips")
            }
        }
    }

    /// Whether stepping back another period would still overlap the data.
    /// Without this the chevron pages into empty weeks forever.
    private var canNavigateBack: Bool {
        guard let earliest = trips.map(\.startDate).min() else { return false }
        return (isDailySummaryData ? selectedWeekStart : selectedDayStart) > earliest
    }

    private var periodNavigatorView: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { periodOffset -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(canNavigateBack ? .primary : .secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateBack)

            Spacer()

            VStack(spacing: 2) {
                Text(periodLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(periodSubLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { periodOffset += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(periodOffset < 0 ? .primary : .secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(periodOffset >= 0)
        }
    }

    private var energyUsageChartView: some View {
        Group {
            if showEnergyBreakdown {
                stackedEnergyChart
            } else {
                totalEnergyChart
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showEnergyBreakdown)
        .animation(.easeInOut(duration: 0.25), value: periodOffset)
        .padding(.horizontal)
    }

    /// Indexed trips for categorical x-axis (oldest first for left-to-right display)
    private var indexedTrips: [(index: Int, trip: EVTripSummary)] {
        Array(tripsForSelectedPeriod.reversed().enumerated().map { ($0.offset, $0.element) })
    }

    /// Day-summary data (EU /drvhistory) reports whole days: no per-trip
    /// times, so every summary carries zero duration — and those regions are
    /// the ones that declare the per-trip drill-down capability. Keying off
    /// the model rather than midnight timestamps keeps a real trip that
    /// happens to start at 12:00 AM from flipping the view into weekly mode.
    private var isDailySummaryData: Bool {
        guard !trips.isEmpty else { return false }
        return supportsTripInfo || trips.allSatisfy { $0.duration == .zero }
    }

    private func formatTripLabel(_ date: Date) -> String {
        if isDailySummaryData {
            return date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            return date.formatted(.dateTime.hour().minute())
        }
    }

    private var totalEnergyChart: some View {
        Chart(indexedTrips, id: \.index) { item in
            BarMark(
                x: .value("Trip", formatTripLabel(item.trip.startDate)),
                y: .value("Energy", Double(item.trip.totalEnergyUsed) / 1000.0)
            )
            .foregroundStyle(by: .value("Category", "Total"))
            .cornerRadius(4)
        }
        .chartForegroundStyleScale([
            "Total": Color.orange
        ])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let energy = value.as(Double.self) {
                        Text(String(format: "%.1f", energy))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxisLabel("kWh", position: .leading)
        .chartLegend(position: .bottom, spacing: 8)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: 7)
    }

    private var stackedEnergyChart: some View {
        Chart(energyBreakdownData) { dataPoint in
            BarMark(
                x: .value("Trip", dataPoint.tripLabel),
                y: .value("Energy", dataPoint.energy)
            )
            .foregroundStyle(by: .value("Category", dataPoint.category))
            .cornerRadius(4)
        }
        .chartForegroundStyleScale([
            "Drivetrain": Color.orange,
            "Climate": Color.blue,
            "Accessories": Color.purple,
            "Battery Care": Color.cyan
        ])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let energy = value.as(Double.self) {
                        Text(String(format: "%.1f", energy))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxisLabel("kWh", position: .leading)
        .chartLegend(position: .bottom, spacing: 8)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: 7)
    }

    /// Data points for the stacked energy breakdown chart
    private var energyBreakdownData: [EnergyDataPoint] {
        indexedTrips.flatMap { item -> [EnergyDataPoint] in
            let tripLabel = formatTripLabel(item.trip.startDate)
            var points: [EnergyDataPoint] = [
                EnergyDataPoint(
                    tripLabel: tripLabel,
                    category: "Drivetrain",
                    energy: Double(item.trip.drivetrainEnergy) / 1000.0
                ),
                EnergyDataPoint(
                    tripLabel: tripLabel,
                    category: "Climate",
                    energy: Double(item.trip.climateEnergy) / 1000.0
                ),
                EnergyDataPoint(
                    tripLabel: tripLabel,
                    category: "Accessories",
                    energy: Double(item.trip.accessoriesEnergy) / 1000.0
                )
            ]
            if item.trip.batteryCareEnergy > 0 {
                points.append(EnergyDataPoint(
                    tripLabel: tripLabel,
                    category: "Battery Care",
                    energy: Double(item.trip.batteryCareEnergy) / 1000.0
                ))
            }
            return points
        }
    }

    // MARK: - Period helpers

    private var selectedWeekStart: Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        comps.weekday = 2 // Monday
        let thisMonday = cal.date(from: comps) ?? Date()
        return cal.date(byAdding: .weekOfYear, value: periodOffset, to: thisMonday) ?? Date()
    }

    private var selectedWeekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? Date()
    }

    private var selectedDayStart: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: periodOffset, to: today) ?? today
    }

    private var selectedDayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: selectedDayStart) ?? Date()
    }

    private var periodLabel: String {
        let fmt = DateFormatter()
        if isDailySummaryData {
            fmt.dateFormat = "MMM d"
            let end = Calendar.current.date(byAdding: .day, value: 6, to: selectedWeekStart) ?? selectedWeekEnd
            return "\(fmt.string(from: selectedWeekStart)) – \(fmt.string(from: end))"
        } else {
            fmt.dateFormat = "EEE, MMM d"
            return fmt.string(from: selectedDayStart)
        }
    }

    private var periodSubLabel: String {
        if isDailySummaryData {
            switch periodOffset {
            case 0:  return "This Week"
            case -1: return "Last Week"
            default: return "\(-periodOffset) weeks ago"
            }
        } else {
            switch periodOffset {
            case 0:  return "Today"
            case -1: return "Yesterday"
            default: return "\(-periodOffset) days ago"
            }
        }
    }

    private var tripsForSelectedPeriod: [EVTripSummary] {
        if isDailySummaryData {
            return trips.filter { $0.startDate >= selectedWeekStart && $0.startDate < selectedWeekEnd }
        } else {
            return trips.filter { $0.startDate >= selectedDayStart && $0.startDate < selectedDayEnd }
        }
    }

    private var supportsTripInfo: Bool {
        bbVehicle.account?.supportedEVTripTypes.contains(.info) == true
    }

    private func loadTripDetails() async {
        isLoading = true
        loadError = nil

        guard let account = bbVehicle.account else {
            loadError = ActionError(
                action: "Load trip history",
                error: APIError(message: "Vehicle account not found")
            )
            isLoading = false
            return
        }

        do {
            if let fetchedTrips = try await account.fetchEVTripSummary(for: bbVehicle, modelContext: modelContext) {
                trips = fetchedTrips
                await loadDetailedTripsForSelectedPeriod()
            } else {
                loadError = ActionError(
                    action: "Load trip history",
                    error: APIError(
                        message: "Trip details are not available for this vehicle.",
                        apiName: account.brandEnum.displayName
                    ),
                    accountId: account.id
                )
            }
        } catch {
            BBLogger.error(.api, "TripDetailsView: Failed to fetch trip details: \(error)")
            loadError = ActionError(
                action: "Load trip history",
                error: error,
                accountId: account.id
            )
        }

        isLoading = false
    }

    private func loadDetailedTripsForSelectedPeriod() async {
        guard supportsTripInfo, let account = bbVehicle.account else { return }
        
        let tripsToFetch = tripsForSelectedPeriod.filter { detailedTrips[$0.startDate] == nil }
        guard !tripsToFetch.isEmpty else { return }
        
        for trip in tripsToFetch {
            let date = trip.startDate
            do {
                let info = try await account.fetchEVTripInfo(for: bbVehicle, date: date, modelContext: modelContext)
                if let info = info {
                    detailedTrips[date] = info.sorted(by: { $0.date > $1.date })
                } else {
                    detailedTrips[date] = []
                }
            } catch {
                BBLogger.error(.api, "TripDetailsView: Failed to fetch detailed trips for \(date): \(error)")
                detailedTrips[date] = []
            }
        }
    }
}

// MARK: - Energy Data Point

/// Data point for the stacked energy breakdown chart
struct EnergyDataPoint: Identifiable {
    let id = UUID()
    let tripLabel: String
    let category: String
    let energy: Double
}

// MARK: - Trip Detail Row

struct TripDetailRow: View {
    let trip: EVTripSummary
    let distanceUnit: Distance.Units
    let isDailySummary: Bool
    var bbVehicle: BBVehicle? = nil
    var supportsTripInfo: Bool = false
    var detailedTrips: [EVTripInfo]? = nil
    @State private var isExpanded = false

    /// EVTripInfo speeds arrive in the API's native unit, which matches the
    /// detail's own distance units (km/h for Europe).
    private var detailSpeedUnits: Distance.Units {
        detailedTrips?.first?.distance.units ?? .kilometers
    }

    private var effectiveAvgSpeed: Int {
        if let detailedTrips = detailedTrips, !detailedTrips.isEmpty {
            let validSpeeds = detailedTrips.filter { $0.avgSpeed > 0 }
            if validSpeeds.isEmpty { return Int(trip.avgSpeed) }
            let avg = validSpeeds.reduce(0.0) { $0 + $1.avgSpeed } / Double(validSpeeds.count)
            return Int(detailSpeedUnits.convert(avg, to: distanceUnit))
        }
        return Int(trip.avgSpeed)
    }

    private var effectiveMaxSpeed: Int {
        if let detailedTrips = detailedTrips, !detailedTrips.isEmpty {
            let max = detailedTrips.map { $0.maxSpeed }.max() ?? 0
            return max > 0 ? Int(detailSpeedUnits.convert(max, to: distanceUnit)) : Int(trip.maxSpeed)
        }
        return Int(trip.maxSpeed)
    }

    private var speedUnitString: String {
        distanceUnit == .miles ? "mph" : "km/h"
    }

    private var effectiveDurationString: String {
        if let detailedTrips = detailedTrips, !detailedTrips.isEmpty {
            let totalSeconds = detailedTrips.reduce(0 as Int64) { $0 + $1.driveTime.components.seconds }
            if totalSeconds > 0 {
                return Duration.seconds(totalSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            }
        }
        return trip.formattedDuration
    }

    private var formattedDistance: String {
        trip.distance.units.format(trip.distance.length, to: distanceUnit)
    }

    private var formattedEfficiency: String {
        String(format: "%.1f %@/kWh", trip.efficiency(in: distanceUnit), distanceUnit.abbreviation)
    }

    private var formattedTotalEnergy: String {
        if trip.totalEnergyUsed >= 1000 {
            return String(format: "%.1f kWh", Double(trip.totalEnergyUsed) / 1000.0)
        } else {
            return "\(trip.totalEnergyUsed) Wh"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Touchable Header Area
            VStack(alignment: .leading, spacing: 8) {
                // Header row with date and distance (never animates)
            HStack {
                if isDailySummary {
                    Text(
                        trip.startDate,
                        format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                } else {
                    Text(
                        trip.startDate,
                        format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                }
                Spacer()
                Text(formattedDistance)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .animation(nil, value: isExpanded)

            // Summary row (never animates except chevron)
            HStack {
                Text(effectiveDurationString)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("•")
                    .foregroundColor(.secondary)

                Text(formattedTotalEnergy)
                    .font(.caption)
                    .foregroundColor(.orange)

                Text("•")
                    .foregroundColor(.secondary)

                Text(formattedEfficiency)
                    .font(.caption)
                    .foregroundColor(.green)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
            .animation(nil, value: isExpanded)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }

        // Expanded energy breakdown
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if trip.batteryCareEnergy > 0 {
                        // Two rows when battery care is present
                        HStack(spacing: 8) {
                            EnergyBreakdownPill(
                                label: "Drivetrain",
                                value: trip.drivetrainEnergy,
                                color: .orange
                            )
                            EnergyBreakdownPill(
                                label: "Regen",
                                value: trip.regenEnergy,
                                color: .green
                            )
                            EnergyBreakdownPill(
                                label: "Climate",
                                value: trip.climateEnergy,
                                color: .blue
                            )
                        }
                        HStack(spacing: 8) {
                            EnergyBreakdownPill(
                                label: "Accessories",
                                value: trip.accessoriesEnergy,
                                color: .purple
                            )
                            EnergyBreakdownPill(
                                label: "Batt Care",
                                value: trip.batteryCareEnergy,
                                color: .cyan
                            )
                            Spacer()
                        }
                    } else {
                        // Single row when no battery care
                        HStack(spacing: 8) {
                            EnergyBreakdownPill(
                                label: "Drivetrain",
                                value: trip.drivetrainEnergy,
                                color: .orange
                            )
                            EnergyBreakdownPill(
                                label: "Regen",
                                value: trip.regenEnergy,
                                color: .green
                            )
                            EnergyBreakdownPill(
                                label: "Climate",
                                value: trip.climateEnergy,
                                color: .blue
                            )
                            EnergyBreakdownPill(
                                label: "Accessories",
                                value: trip.accessoriesEnergy,
                                color: .purple
                            )
                        }
                    }

                    // Speed info
                    HStack {
                        Text("Avg: \(effectiveAvgSpeed) \(speedUnitString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("Max: \(effectiveMaxSpeed) \(speedUnitString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    if supportsTripInfo {
                        Divider()
                            .padding(.vertical, 4)
                            
                        if let detailedTrips = detailedTrips {
                            if detailedTrips.isEmpty {
                                Text("No individual trips found.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                VStack(spacing: 6) {
                                    ForEach(detailedTrips, id: \.self) { detail in
                                        TripInfoPillView(trip: detail, distanceUnit: distanceUnit)
                                    }
                                }
                            }
                        } else {
                            ProgressView("Loading trips...")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Energy Breakdown Pill

struct EnergyBreakdownPill: View {
    let label: String
    let value: Int
    let color: Color

    private var formattedValue: String {
        if value >= 1000 {
            return String(format: "%.1f kWh", Double(value) / 1000.0)
        } else {
            return "\(value) Wh"
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(formattedValue)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Trip Info Pill

struct TripInfoPillView: View {
    let trip: EVTripInfo
    let distanceUnit: Distance.Units

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(trip.distance.units.format(trip.distance.length, to: distanceUnit))
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(width: 65, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Drive")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(trip.driveTime.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Idle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(trip.idleTime.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(.tertiarySystemFill))
        .cornerRadius(8)
    }
}

// MARK: - Previews

extension EVTripSummary {
    static var sample: EVTripSummary {
        EVTripSummary(
            distance: Distance(length: 7, units: .miles),
            odometer: Distance(length: 14214.1, units: .miles),
            accessoriesEnergy: 220,
            totalEnergyUsed: 3090,
            regenEnergy: 966,
            climateEnergy: 1235,
            drivetrainEnergy: 1635,
            batteryCareEnergy: 0,
            startDate: Date().addingTimeInterval(-3600),
            duration: .seconds(1268),
            avgSpeed: 27.0,
            maxSpeed: 41.0
        )
    }

    /// A day-summary shaped sample (zero duration/speeds, km distance),
    /// matching what the EU /drvhistory endpoint returns.
    static var sampleDaySummary: EVTripSummary {
        EVTripSummary(
            distance: Distance(length: 53, units: .kilometers),
            odometer: Distance(length: 0, units: .kilometers),
            accessoriesEnergy: 528,
            totalEnergyUsed: 5311,
            regenEnergy: 3785,
            climateEnergy: 216,
            drivetrainEnergy: 6027,
            batteryCareEnergy: 0,
            startDate: Calendar.current.startOfDay(for: Date()),
            duration: .zero,
            avgSpeed: 0,
            maxSpeed: 0
        )
    }
}

extension EVTripInfo {
    static var sampleTrips: [EVTripInfo] {
        [
            EVTripInfo(
                date: Date().addingTimeInterval(-7200),
                driveTime: .seconds(22 * 60),
                idleTime: .seconds(3 * 60),
                distance: Distance(length: 12.4, units: .kilometers),
                avgSpeed: 34,
                maxSpeed: 61
            ),
            EVTripInfo(
                date: Date().addingTimeInterval(-30_000),
                driveTime: .seconds(41 * 60),
                idleTime: .seconds(6 * 60),
                distance: Distance(length: 40.6, units: .kilometers),
                avgSpeed: 52,
                maxSpeed: 118
            )
        ]
    }
}

#Preview("Trip Row (per-trip region)") {
    List {
        TripDetailRow(
            trip: .sample,
            distanceUnit: .miles,
            isDailySummary: false
        )
    }
}

#Preview("Day Summary Row (EU, drill-down)") {
    List {
        TripDetailRow(
            trip: .sampleDaySummary,
            distanceUnit: .kilometers,
            isDailySummary: true,
            supportsTripInfo: true,
            detailedTrips: EVTripInfo.sampleTrips
        )
    }
}
