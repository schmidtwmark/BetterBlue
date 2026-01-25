//
//  TripDetailsView.swift
//  BetterBlue
//
//  View for displaying EV trip details and efficiency chart
//

import BetterBlueKit
import Charts
import SwiftUI

struct TripDetailsView: View {
    let bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @State private var trips: [EVTripDetail] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var appSettings = AppSettings.shared
    @State private var showEnergyBreakdown = false

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
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
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading trip details...")
                .foregroundColor(.secondary)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Failed to load trips")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
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
                ForEach(trips) { trip in
                    TripDetailRow(trip: trip, distanceUnit: appSettings.preferredDistanceUnit)
                }
            } header: {
                Text("Recent Trips")
            }
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
        .padding(.horizontal)
    }

    /// Indexed trips for categorical x-axis (oldest first for left-to-right display)
    private var indexedTrips: [(index: Int, trip: EVTripDetail)] {
        Array(trips.reversed().enumerated().map { ($0.offset, $0.element) })
    }

    private func formatTripTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private var totalEnergyChart: some View {
        Chart(indexedTrips, id: \.index) { item in
            BarMark(
                x: .value("Trip", formatTripTime(item.trip.startDate)),
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
    }

    /// Data points for the stacked energy breakdown chart
    private var energyBreakdownData: [EnergyDataPoint] {
        indexedTrips.flatMap { item -> [EnergyDataPoint] in
            let tripLabel = formatTripTime(item.trip.startDate)
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

    private func loadTripDetails() async {
        isLoading = true
        errorMessage = nil

        guard let account = bbVehicle.account else {
            errorMessage = "Vehicle account not found"
            isLoading = false
            return
        }

        do {
            if let fetchedTrips = try await account.fetchEVTripDetails(for: bbVehicle, modelContext: modelContext) {
                trips = fetchedTrips
            } else {
                errorMessage = "Trip details not available for this vehicle"
            }
        } catch {
            BBLogger.error(.api, "TripDetailsView: Failed to fetch trip details: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
    let trip: EVTripDetail
    let distanceUnit: Distance.Units
    @State private var isExpanded = false

    private var formattedDistance: String {
        Distance.Units.miles.format(trip.distance, to: distanceUnit)
    }

    private var formattedEfficiency: String {
        String(format: "%.1f mi/kWh", trip.efficiency)
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
            // Header row with date and distance (never animates)
            HStack {
                Text(
                    trip.startDate,
                    format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                )
                .font(.subheadline)
                .fontWeight(.medium)
                Spacer()
                Text(formattedDistance)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .animation(nil, value: isExpanded)

            // Summary row (never animates except chevron)
            HStack {
                Text(trip.formattedDuration)
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
                        Text("Avg: \(Int(trip.avgSpeed)) mph")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("Max: \(Int(trip.maxSpeed)) mph")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
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

// MARK: - Previews

#Preview("Trip Details - With Data") {
    NavigationView {
        TripDetailsPreviewWrapper(trips: EVTripDetail.sampleTrips)
    }
}

#Preview("Trip Details - Loading") {
    NavigationView {
        TripDetailsPreviewWrapper(trips: nil, isLoading: true)
    }
}

#Preview("Trip Details - Empty") {
    NavigationView {
        TripDetailsPreviewWrapper(trips: [])
    }
}

#Preview("Trip Details - Error") {
    NavigationView {
        TripDetailsPreviewWrapper(trips: nil, errorMessage: "Failed to connect to server")
    }
}

#Preview("Trip Row") {
    List {
        TripDetailRow(
            trip: .sample,
            distanceUnit: .miles
        )
    }
}

// MARK: - Preview Helpers

private struct TripDetailsPreviewWrapper: View {
    let trips: [EVTripDetail]?
    var isLoading: Bool = false
    var errorMessage: String? = nil

    var body: some View {
        TripDetailsPreviewContent(
            trips: trips ?? [],
            isLoading: isLoading,
            errorMessage: errorMessage
        )
        .navigationTitle("Trip History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TripDetailsPreviewContent: View {
    let trips: [EVTripDetail]
    let isLoading: Bool
    let errorMessage: String?
    @State private var appSettings = AppSettings.shared
    @State private var showEnergyBreakdown = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading trip details...")
                        .foregroundColor(.secondary)
                }
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Failed to load trips")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {}
                        .buttonStyle(.bordered)
                }
                .padding()
            } else if trips.isEmpty {
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
            } else {
                List {
                    Section {
                        Group {
                            if showEnergyBreakdown {
                                stackedEnergyChart
                            } else {
                                totalEnergyChart
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: showEnergyBreakdown)
                        .padding(.horizontal)
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

                    Section {
                        ForEach(trips) { trip in
                            TripDetailRow(trip: trip, distanceUnit: appSettings.preferredDistanceUnit)
                        }
                    } header: {
                        Text("Recent Trips")
                    }
                }
            }
        }
    }

    private var indexedTrips: [(index: Int, trip: EVTripDetail)] {
        Array(trips.reversed().enumerated().map { ($0.offset, $0.element) })
    }

    private func formatTripTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private var totalEnergyChart: some View {
        Chart(indexedTrips, id: \.index) { item in
            BarMark(
                x: .value("Trip", formatTripTime(item.trip.startDate)),
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
    }

    private var energyBreakdownData: [EnergyDataPoint] {
        indexedTrips.flatMap { item -> [EnergyDataPoint] in
            let tripLabel = formatTripTime(item.trip.startDate)
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
}

// MARK: - Sample Data

extension EVTripDetail {
    static var sample: EVTripDetail {
        EVTripDetail(
            distance: 7,
            odometer: 14214.1,
            accessoriesEnergy: 220,
            totalEnergyUsed: 3090,
            regenEnergy: 966,
            climateEnergy: 1235,
            drivetrainEnergy: 1635,
            batteryCareEnergy: 0,
            startDate: Date().addingTimeInterval(-3600),
            durationSeconds: 1268,
            avgSpeed: 27.0,
            maxSpeed: 41.0
        )
    }

    static var sampleTrips: [EVTripDetail] {
        [
            EVTripDetail(
                distance: 7,
                odometer: 14214.1,
                accessoriesEnergy: 220,
                totalEnergyUsed: 3090,
                regenEnergy: 966,
                climateEnergy: 1235,
                drivetrainEnergy: 1635,
                batteryCareEnergy: 0,
                startDate: Date().addingTimeInterval(-3600),
                durationSeconds: 1268,
                avgSpeed: 27.0,
                maxSpeed: 41.0
            ),
            EVTripDetail(
                distance: 4,
                odometer: 14206.1,
                accessoriesEnergy: 160,
                totalEnergyUsed: 2677,
                regenEnergy: 446,
                climateEnergy: 908,
                drivetrainEnergy: 1409,
                batteryCareEnergy: 200,
                startDate: Date().addingTimeInterval(-7200),
                durationSeconds: 932,
                avgSpeed: 24.0,
                maxSpeed: 42.0
            ),
            EVTripDetail(
                distance: 4,
                odometer: 14200.9,
                accessoriesEnergy: 70,
                totalEnergyUsed: 2116,
                regenEnergy: 364,
                climateEnergy: 569,
                drivetrainEnergy: 1177,
                batteryCareEnergy: 300,
                startDate: Date().addingTimeInterval(-10800),
                durationSeconds: 526,
                avgSpeed: 34.0,
                maxSpeed: 59.0
            ),
            EVTripDetail(
                distance: 6,
                odometer: 14196.5,
                accessoriesEnergy: 90,
                totalEnergyUsed: 2583,
                regenEnergy: 1334,
                climateEnergy: 769,
                drivetrainEnergy: 1524,
                batteryCareEnergy: 200,
                startDate: Date().addingTimeInterval(-14400),
                durationSeconds: 752,
                avgSpeed: 32.0,
                maxSpeed: 51.0
            )
        ]
    }
}
