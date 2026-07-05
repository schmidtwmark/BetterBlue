//
//  WatchComplications.swift
//  WatchWidget
//
//  Created by Mark Schmidt on 1/25/26.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry and Provider

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let vehicleName: String?
    let rangeText: String?
    let batteryPercentage: Double?
    /// Drives the ring's gap glyph (bolt vs fuel pump).
    var isElectric: Bool = true
}

struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(
            date: Date(),
            vehicleName: "Vehicle",
            rangeText: "-- mi",
            batteryPercentage: 75
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        Task { @MainActor in
            let entry = await fetchEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        Task { @MainActor in
            let entry = await fetchEntry()
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    @MainActor
    private func fetchEntry() async -> WatchComplicationEntry {
        do {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)
            let context = ModelContext(modelContainer)
            let vehicles = try context.fetch(FetchDescriptor<BBVehicle>(
                predicate: #Predicate { !$0.isHidden },
                sortBy: [SortDescriptor(\.sortOrder)]
            ))

            guard let vehicle = vehicles.first else {
                return WatchComplicationEntry(date: Date(), vehicleName: nil, rangeText: nil, batteryPercentage: nil)
            }

            let settings = AppSettings.shared
            var rangeText: String?
            var percentage: Double?

            if vehicle.fuelType.hasElectricCapability, let evStatus = vehicle.evStatus {
                percentage = evStatus.evRange.percentage
                if evStatus.evRange.range.length > 0 {
                    rangeText = evStatus.evRange.range.units.format(
                        evStatus.evRange.range.length,
                        to: settings.preferredDistanceUnit
                    )
                }
            } else if let gasRange = vehicle.gasRange {
                percentage = gasRange.percentage
                if gasRange.range.length > 0 {
                    rangeText = gasRange.range.units.format(
                        gasRange.range.length,
                        to: settings.preferredDistanceUnit
                    )
                }
            }

            return WatchComplicationEntry(
                date: Date(),
                vehicleName: vehicle.displayName,
                rangeText: rangeText,
                batteryPercentage: percentage,
                isElectric: vehicle.fuelType.hasElectricCapability
            )
        } catch {
            BBLogger.error(.app, "WatchComplicationProvider: \(error)")
            return WatchComplicationEntry(date: Date(), vehicleName: nil, rangeText: nil, batteryPercentage: nil)
        }
    }
}

// MARK: - Vehicle Status Complication

struct VehicleStatusComplication: Widget {
    let kind = "com.betterblue.watch.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            VehicleStatusComplicationView(entry: entry)
        }
        .configurationDisplayName("BetterBlue")
        .description("View vehicle battery and range")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

/// Battery-widget-style ring, identical in construction to the iOS
/// lock-screen `VehicleRingGauge`: the SYSTEM accessoryCircular gauge
/// (270° arc, bottom gap, rounded caps — the same rendering the built-in
/// battery complication uses), fuel glyph in the gap, configurable center.
struct WatchRingGauge: View {
    enum Center { case percentage, range }
    let entry: WatchComplicationEntry
    let center: Center

    /// "203 mi" → ("203", "mi") so the unit renders small under the
    /// number inside the ring; non-splittable text passes through whole.
    private var rangeParts: (String, String?) {
        guard let range = entry.rangeText else { return ("--", nil) }
        let parts = range.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (range, nil) }
        return (String(parts[0]), String(parts[1]))
    }

    var body: some View {
        if let percentage = entry.batteryPercentage {
            Gauge(value: percentage, in: 0 ... 100) {
                Image(systemName: entry.isElectric ? "bolt.fill" : "fuelpump.fill")
            } currentValueLabel: {
                switch center {
                case .percentage:
                    // Bare number, matching the system battery ring.
                    Text("\(Int(percentage.rounded()))")
                        .font(.system(.body, design: .rounded))
                case .range:
                    let (value, unit) = rangeParts
                    VStack(spacing: -2) {
                        Text(value)
                            .font(.system(.body, design: .rounded))
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
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "car.fill")
                    .font(.title2)
            }
        }
    }
}

struct VehicleStatusComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchRingGauge(entry: entry, center: .percentage)
        case .accessoryCorner:
            Image(systemName: "car.fill")
                .font(.title2)
                .widgetLabel {
                    if let range = entry.rangeText {
                        Text(range)
                    } else if let name = entry.vehicleName {
                        Text(name)
                    } else {
                        Text("BetterBlue")
                    }
                }
        case .accessoryRectangular:
            // Mirrors the iOS 2x1 lock-screen widget: percentage ring
            // beside the vehicle name and range.
            HStack(spacing: 10) {
                WatchRingGauge(entry: entry, center: .percentage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.vehicleName ?? "BetterBlue")
                        .font(.headline)
                        .lineLimit(1)
                    if let range = entry.rangeText {
                        Text(range)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        case .accessoryInline:
            if let range = entry.rangeText {
                Label(range, systemImage: "car.fill")
            } else {
                Label("BetterBlue", systemImage: "car.fill")
            }
        default:
            Image(systemName: "car.fill")
        }
    }
}

// MARK: - Vehicle Range Complication

/// Circular ring with the remaining RANGE in the center instead of the
/// percentage. Its own kind so it sits alongside the existing percentage
/// complication in the gallery — existing placements keep working and
/// pick up the refreshed ring automatically.
struct VehicleRangeComplication: Widget {
    let kind = "com.betterblue.watch.range"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchRingGauge(entry: entry, center: .range)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Vehicle Range")
        .description("Battery or fuel ring with the remaining range")
        .supportedFamilies([.accessoryCircular])
    }
}
