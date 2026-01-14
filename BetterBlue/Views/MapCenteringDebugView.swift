//
//  MapCenteringDebugView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/7/25.
//

import SwiftUI

struct MapCenteringDebugView: View {
    @AppStorage("debug_map_aggressive_multiplier") private var aggressiveMultiplier: Double = 2.5
    @AppStorage("debug_map_minimum_offset") private var minimumOffset: Double = 0.003
    @AppStorage("debug_map_marker_height_offset") private var markerHeightOffset: Double = 0.001
    @AppStorage("debug_map_fallback_offset") private var fallbackOffset: Double = 0.008
    @AppStorage("debug_map_recenter_threshold") private var recenterThreshold: Double = 0.0005

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Aggressive Multiplier")
                    Spacer()
                    Text(String(format: "%.1fx", aggressiveMultiplier))
                        .foregroundColor(.secondary)
                }
                Slider(value: $aggressiveMultiplier, in: 1.0 ... 5.0, step: 0.1)

                HStack {
                    Text("Minimum Offset")
                    Spacer()
                    Text(String(format: "%.3f°", minimumOffset))
                        .foregroundColor(.secondary)
                }
                Slider(value: $minimumOffset, in: 0.001 ... 0.010, step: 0.001)

                HStack {
                    Text("Marker Height Offset")
                    Spacer()
                    Text(String(format: "%.3f°", markerHeightOffset))
                        .foregroundColor(.secondary)
                }
                Slider(value: $markerHeightOffset, in: 0.000 ... 0.005, step: 0.001)

                HStack {
                    Text("Fallback Offset")
                    Spacer()
                    Text(String(format: "%.3f°", fallbackOffset))
                        .foregroundColor(.secondary)
                }
                Slider(value: $fallbackOffset, in: 0.003 ... 0.015, step: 0.001)

                HStack {
                    Text("Recenter Threshold")
                    Spacer()
                    Text(String(format: "%.4f°", recenterThreshold))
                        .foregroundColor(.secondary)
                }
                Slider(value: $recenterThreshold, in: 0.0001 ... 0.002, step: 0.0001)

            } header: {
                Text("Centering Parameters")
            } footer: {
                Text("These parameters control how the map centers vehicles. " +
                    "Higher values create more offset. Changes apply immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    aggressiveMultiplier = 2.5
                    minimumOffset = 0.003
                    markerHeightOffset = 0.001
                    fallbackOffset = 0.008
                    recenterThreshold = 0.0005
                }
                .foregroundColor(.blue)

                Button("Conservative (Less Offset)") {
                    aggressiveMultiplier = 1.5
                    minimumOffset = 0.002
                    markerHeightOffset = 0.001
                    fallbackOffset = 0.005
                    recenterThreshold = 0.0008
                }
                .foregroundColor(.green)

                Button("Aggressive (More Offset)") {
                    aggressiveMultiplier = 3.5
                    minimumOffset = 0.005
                    markerHeightOffset = 0.002
                    fallbackOffset = 0.012
                    recenterThreshold = 0.0003
                }
                .foregroundColor(.orange)

                Button("Maximum (Extreme Offset)") {
                    aggressiveMultiplier = 5.0
                    minimumOffset = 0.008
                    markerHeightOffset = 0.003
                    fallbackOffset = 0.015
                    recenterThreshold = 0.0002
                }
                .foregroundColor(.red)
            } header: {
                Text("Quick Presets")
            } footer: {
                Text("Try different presets to see how they affect map centering.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ParameterExplanation(
                        title: "Aggressive Multiplier",
                        description: "Amplifies the calculated offset. Higher values create more pronounced centering.",
                        range: "1.0x - 5.0x",
                        recommended: "2.5x - 3.5x",
                    )

                    Divider()

                    ParameterExplanation(
                        title: "Minimum Offset",
                        description: "Minimum distance to move the map center. " +
                            "Ensures meaningful adjustment even on small screens.",
                        range: "0.001° - 0.010°",
                        recommended: "0.003° - 0.005°",
                    )

                    Divider()

                    ParameterExplanation(
                        title: "Marker Height Offset",
                        description: "Extra offset to account for the visual height of the vehicle marker.",
                        range: "0.000° - 0.005°",
                        recommended: "0.001° - 0.002°",
                    )

                    Divider()

                    ParameterExplanation(
                        title: "Fallback Offset",
                        description: "Used when screen dimensions are unknown. Should be larger for safety.",
                        range: "0.003° - 0.015°",
                        recommended: "0.008° - 0.012°",
                    )

                    Divider()

                    ParameterExplanation(
                        title: "Recenter Threshold",
                        description: "How far the map must drift before showing the recenter button.",
                        range: "0.0001° - 0.002°",
                        recommended: "0.0003° - 0.0008°",
                    )
                }
            } header: {
                Text("Parameter Guide")
            } footer: {
                Text("1° latitude ≈ 111km. 0.001° ≈ 111 meters. " +
                    "Watch the debug console for real-time centering calculations.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Map Centering Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ParameterExplanation: View {
    let title: String
    let description: String
    let range: String
    let recommended: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)

            HStack {
                Text("Range: \(range)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Recommended: \(recommended)")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
    }
}

#Preview {
    NavigationView {
        MapCenteringDebugView()
    }
}
