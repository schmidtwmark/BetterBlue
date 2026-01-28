//
//  VehicleInfoComponents.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct VehicleBasicInfoSection: View {
    let bbVehicle: BBVehicle
    @Binding var showingCopiedMessage: Bool

    var body: some View {
        Section("Basic Information") {
            HStack {
                Text("Original Name")
                Spacer()
                Text(bbVehicle.model)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Brand")
                Spacer()
                if let account = bbVehicle.account {
                    Text(account.brandEnum.displayName)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("VIN")
                Spacer()
                Text(bbVehicle.vin)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                copyVINToClipboard()
            }
        }
    }

    private func copyVINToClipboard() {
        UIPasteboard.general.string = bbVehicle.vin

        withAnimation(.easeInOut(duration: 0.3)) {
            showingCopiedMessage = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingCopiedMessage = false
            }
        }
    }
}

struct VehicleWidgetConfigSection: View {
    let bbVehicle: BBVehicle

    var body: some View {
        Section {
            NavigationLink(destination: BackgroundSelectionView(bbVehicle: bbVehicle)) {
                HStack {
                    Text("Background")
                    Spacer()
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: bbVehicle.backgroundGradient),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing,
                            ))
                            .frame(width: 24, height: 16)
                        Text(BBVehicle.availableBackgrounds.first(
                            where: { $0.name == bbVehicle.backgroundColorName },
                        )?.displayName ?? "Default")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Widget Appearance")
        }
    }
}
