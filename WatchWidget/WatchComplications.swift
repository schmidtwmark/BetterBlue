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
            let modelContainer = try createSharedModelContainer()
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

            if vehicle.isElectric, let evStatus = vehicle.evStatus {
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
                batteryPercentage: percentage
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
            .accessoryInline,
        ])
    }
}

struct VehicleStatusComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                if let percentage = entry.batteryPercentage {
                    Gauge(value: percentage, in: 0...100) {
                        Image(systemName: "car.fill")
                    } currentValueLabel: {
                        Text("\(Int(percentage))")
                            .font(.system(.body, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircular)
                } else {
                    AccessoryWidgetBackground()
                    Image(systemName: "car.fill")
                        .font(.title2)
                }
            }
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
            HStack {
                Image(systemName: "car.fill")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(entry.vehicleName ?? "BetterBlue")
                        .font(.headline)
                    if let range = entry.rangeText {
                        Text(range)
                            .font(.caption)
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
