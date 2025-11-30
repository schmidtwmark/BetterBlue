//
//  TemperatureArcControl.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftUI

struct TemperatureArcControl: View {
    @Binding var temperature: Temperature
    let preferredUnit: Temperature.Units
    @State private var isDragging = false

    private var temperatureRange: ClosedRange<Double> {
        temperature.units.hvacRange
    }

    private var displayValue: String {
        temperature.units.format(temperature.value, to: preferredUnit)
    }

    private var normalizedValue: Double {
        (temperature.value - temperatureRange.lowerBound) / (temperatureRange.upperBound - temperatureRange.lowerBound)
    }

    private var arcStartAngle: Angle {
        .degrees(225) // Start at bottom-left (3/4 around the circle)
    }

    private var arcEndAngle: Angle {
        .degrees(-45) // End at bottom-right (1/4 around the circle)
    }

    private var totalArcAngle: Double {
        270 // 3/4 of a circle (360 - 90 degrees for the bottom gap)
    }

    private var knobAngle: Angle {
        let progress = normalizedValue
        // The arc is visually rotated 135°, and covers 270° (0.75 of circle)
        // For progress 0-1, we want to map to the bottom 3/4 of the circle
        // Starting from bottom-left going clockwise to bottom-right
        let startAngle = 135.0 // Bottom-left after rotation
        let totalAngle = 270.0 // 3/4 circle
        let angleInDegrees = startAngle + (progress * totalAngle)
        return .degrees(angleInDegrees)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = (size - 40) / 2
            let knobRadius: CGFloat = 12

            ZStack {
                // Background arc
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: size - 40, height: size - 40)

                // Progress arc
                Circle()
                    .trim(from: 0, to: 0.75 * normalizedValue)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.blue,
                                Color.orange
                            ]),
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(270),
                        ),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round),
                    )
                    .rotationEffect(.degrees(135))
                    .frame(width: size - 40, height: size - 40)
                    .animation(.easeInOut(duration: 0.1), value: normalizedValue)

                // Center temperature display
                VStack(spacing: 4) {
                    Text(displayValue)
                        .font(.system(size: 48, weight: .thin, design: .rounded))
                        .foregroundColor(.primary)
                        .animation(.easeInOut(duration: 0.1), value: displayValue)

                    Text("Target Temperature")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Draggable knob
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: isDragging ? knobRadius * 2.4 : knobRadius * 2,
                        height: isDragging ? knobRadius * 2.4 : knobRadius * 2,
                    )
                    .shadow(color: .black.opacity(0.3), radius: isDragging ? 6 : 4, x: 0, y: isDragging ? 3 : 2)
                    .overlay(
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: isDragging ? 1.5 : 1),
                    )
                    .position(
                        x: center.x + cos(knobAngle.radians) * radius,
                        y: center.y + sin(knobAngle.radians) * radius,
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDragging)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                }

                                let vector = CGPoint(
                                    x: value.location.x - center.x,
                                    y: value.location.y - center.y,
                                )

                                // Calculate angle from center, starting from right (0°) going clockwise
                                let angle = atan2(vector.y, vector.x)
                                var degrees = angle * 180 / .pi

                                // Convert to 0-360 range
                                if degrees < 0 {
                                    degrees += 360
                                }

                                // Our arc visually goes from 135° to 405° (135° + 270°)
                                // But 405° = 45°, so it wraps around
                                // The arc covers: 135° -> 180° -> 270° -> 360° -> 45°

                                var progress: Double = 0

                                if degrees >= 135 {
                                    // From 135° to 360° (first part of arc)
                                    progress = (degrees - 135) / 270
                                } else if degrees <= 45 {
                                    // From 0° to 45° (wrapped part of arc)
                                    progress = (degrees + 225) / 270
                                } else {
                                    // In the gap (45° to 135°), snap to closest edge
                                    let distToStart = min(abs(degrees - 135), abs(degrees + 225))
                                    let distToEnd = abs(degrees - 45)

                                    if distToStart < distToEnd {
                                        progress = 0
                                    } else {
                                        progress = 1
                                    }
                                }

                                progress = max(0, min(1, progress))

                                let difference = temperatureRange.upperBound - temperatureRange.lowerBound

                                let newTemp = temperatureRange.lowerBound + progress * difference
                                let roundedTemp = round(newTemp)

                                if roundedTemp != temperature.value {
                                    temperature.value = roundedTemp
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            }
        }
    }
}
