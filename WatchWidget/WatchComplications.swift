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
    /// User-selected ring tint; `.automatic` follows the watch face.
    var tint: WatchComplicationColor = .automatic
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

            // The watch app's Settings can pin the complication to a
            // specific vehicle; otherwise the first visible one. Live
            // read — this extension process outlives settings changes.
            let selectedVIN = AppSettings.liveWatchComplicationVIN()
            let vehicle = vehicles.first(where: { $0.vin == selectedVIN }) ?? vehicles.first
            guard let vehicle else {
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
                isElectric: vehicle.fuelType.hasElectricCapability,
                tint: AppSettings.liveWatchComplicationColor()
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

/// Battery-complication-style ring: `.accessoryCircularCapacity` — the
/// SAME style as the system watch battery complication, so the arc FILLS
/// proportionally instead of the plain accessoryCircular dot-on-a-track
/// marker. No gap glyph in this style, which also stops the unit text
/// from crowding an icon. Tintable from the watch app's Settings.
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
            gauge(percentage)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "car.fill")
                    .font(.title2)
            }
        }
    }

    @ViewBuilder
    private func gauge(_ percentage: Double) -> some View {
        let base = Gauge(value: percentage, in: 0 ... 100) {
            EmptyView()
        } currentValueLabel: {
            switch center {
            case .percentage:
                Text("\(Int(percentage.rounded()))%")
                    .font(.system(.body, design: .rounded))
                    .minimumScaleFactor(0.6)
            case .range:
                let (value, unit) = rangeParts
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5)
                    if let unit {
                        Text(unit.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()

        if let tint = entry.tint.color {
            base.tint(tint)
        } else {
            base
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
            // Range and percentage together, dot-separated — whichever of
            // the two is available ("250 mi · 82%", "82%", …).
            let percentText = entry.batteryPercentage.map { "\(Int($0.rounded()))%" }
            let parts = [entry.rangeText, percentText].compactMap(\.self)
            if parts.isEmpty {
                Label("BetterBlue", systemImage: "car.fill")
            } else {
                Label(parts.joined(separator: " · "), systemImage: "car.fill")
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
