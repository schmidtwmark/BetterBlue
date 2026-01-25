//
//  BackgroundSelectionView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct BackgroundSelectionView: View {
    let bbVehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(BBVehicle.availableBackgrounds, id: \.name) { background in
                Button {
                    bbVehicle.backgroundColorName = background.name
                    do {
                        try modelContext.save()
                        // Force widget timeline refresh to update background
                        WidgetCenter.shared.reloadAllTimelines()
                    } catch {
                        BBLogger.error(.app, "BackgroundSelectionView: Failed to save background color: \(error)")
                    }
                } label: {
                    VStack(spacing: 12) {
                        HStack {
                            Text(background.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)

                            Spacer()

                            if bbVehicle.backgroundColorName == background.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: background.gradient),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing,
                            ))
                            .frame(height: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        bbVehicle.backgroundColorName == background.name ?
                                            Color.blue : Color.clear,
                                        lineWidth: 3,
                                    ),
                            )
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle("Widget Background")
        .navigationBarTitleDisplayMode(.inline)
    }
}
