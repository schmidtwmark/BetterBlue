//
//  SeatHeatControl.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import SwiftUI

struct SeatHeatControl: View {
    @Binding var level: Int
    @Binding var cooling: Bool
    let position: String

    private var activeColor: Color {
        cooling ? .blue : .orange
    }

    private var iconName: String {
        if level > 0 {
            if cooling {
                return "carseat.\(position).fan"
            } else {
                return "carseat.\(position).and.heat.waves"
            }
        }
        return "carseat.\(position)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                level = (level + 1) % 4
            } label: {
                HStack(spacing: 16) {
                    Spacer()

                    Image(systemName: iconName)
                        .font(.title)
                        .foregroundColor(level > 0 ? activeColor : .secondary)
                        .frame(width: 24)

                    VStack(spacing: 4) {
                        Text(position.capitalized)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                Rectangle()
                                    .fill(level > index ? activeColor : Color.gray.opacity(0.3))
                                    .frame(width: 5, height: 12)
                                    .cornerRadius(1.5)
                            }
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: level)
            .animation(.easeInOut(duration: 0.2), value: cooling)

            // Segmented picker for mode selection
            Picker("Mode", selection: $cooling) {
                Text("Heat").tag(false)
                Text("Cool").tag(true)
            }
            .pickerStyle(.segmented)
            .tint(cooling ? .blue : .orange)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            level > 0 ? activeColor.opacity(0.1) : Color.clear
        )
    }
}

#Preview("Seat Heat Control Variants", traits: .sizeThatFitsLayout) {
    StatefulPreviewWrapper((leftLevel: 1, leftCool: false, rightLevel: 2, rightCool: true)) { state in
        HStack(spacing: 16) {
            SeatHeatControl(
                level: state.binding(\.leftLevel),
                cooling: state.binding(\.leftCool),
                position: "left"
            )

            SeatHeatControl(
                level: state.binding(\.rightLevel),
                cooling: state.binding(\.rightCool),
                position: "right"
            )
        }
        .padding()
    }
}

private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initialValue: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initialValue)
        self.content = content
    }

    var body: some View { content($value) }
}

@MainActor
private extension Binding {
    func binding<T>(_ keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding<T>(
            get: { [self, keyPath] in
                self.wrappedValue[keyPath: keyPath]
            },
            set: { [self, keyPath] newValue in
                self.wrappedValue[keyPath: keyPath] = newValue
            }
        )
    }
}
