//
//  VehicleTitleView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/8/25.
//

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI

struct VehicleTitleView: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    let isRefreshing: Bool
    let showRefreshSuccess: Bool
    let onVehicleSelected: (BBVehicle) -> Void
    let accounts: [BBAccount]
    let onRefreshRequested: () async -> Void
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @State private var showingVehicleInfo = false
    @State private var showingAccountInfo = false
    @State private var showingHTTPLogs = false
    @State private var showingVehicleConfiguration = false
    @State private var customVehicleName = ""
    @Namespace private var fallbackTransition

    private var vehicleAccount: BBAccount? {
        bbVehicle.account
    }

    private var safeLocation: VehicleStatus.Location? {
        guard bbVehicle.modelContext != nil else {
            print("⚠️ [VehicleTitleView] BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.location
    }

    var body: some View {
        Menu {
            Menu {
                ForEach(bbVehicles, id: \.id) { vehicle in
                    Button(action: {
                        onVehicleSelected(vehicle)
                    }, label: {
                        HStack {
                            Text(vehicle.displayName)
                            if vehicle.id == bbVehicle.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    })
                }
            } label: {
                Label("Switch Vehicles", systemImage: "iphone.app.switcher")
            }
            Button {
                Task {
                    await onRefreshRequested()
                }
            } label: {
                if showRefreshSuccess {
                    Label("Refreshed", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            if let location = safeLocation {
                let availableApps = NavigationHelper.availableMapApps
                let coordinate = CLLocationCoordinate2D(
                    latitude: location.latitude,
                    longitude: location.longitude,
                )
                let destinationName = bbVehicle.displayName

                if availableApps.count == 1 {
                    Button {
                        NavigationHelper.navigate(
                            using: availableApps[0],
                            to: coordinate,
                            destinationName: destinationName,
                        )
                    } label: {
                        Label("Navigate to Vehicle", systemImage: "location")
                    }
                } else {
                    Menu {
                        NavigationMenuContent(
                            coordinate: coordinate,
                            destinationName: destinationName,
                        )
                    } label: {
                        Label("Navigate to Vehicle", systemImage: "location")
                    }
                }
            }

            Button {
                customVehicleName = bbVehicle.displayName
                showingVehicleInfo = true
            } label: {
                Label("Vehicle Info", systemImage: "car.fill")
            }
            .matchedTransitionSource(id: "vehicle-info", in: transition ?? fallbackTransition)

            Button {
                showingAccountInfo = true
            } label: {
                Label("Account Info", systemImage: "person.circle")
            }
            .matchedTransitionSource(id: "account-info", in: transition ?? fallbackTransition)

            if AppSettings.shared.debugModeEnabled {
                Button {
                    showingHTTPLogs = true
                } label: {
                    Label("HTTP Logs", systemImage: "network")
                }
                .matchedTransitionSource(id: "http-logs", in: transition ?? fallbackTransition)
            }

            if bbVehicle.account?.brandEnum == .fake {
                Button {
                    showingVehicleConfiguration = true
                } label: {
                    Label("Configure Vehicle", systemImage: "gearshape.fill")
                }
                .matchedTransitionSource(id: "vehicle-config", in: transition ?? fallbackTransition)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bbVehicle.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    if let lastUpdated = bbVehicle.lastUpdated {
                        let timeString = formatLastUpdated(lastUpdated)
                        if timeString != "" {
                            Text(timeString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Group {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .transition(.scale.combined(with: .opacity))
                    } else if showRefreshSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                            .transition(.scale(scale: 1.2).combined(with: .opacity))
                            .onAppear {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                                    // Trigger spring animation for checkmark
                                }
                            }
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .transition(.scale.combined(with: .opacity))
                            .animation(
                                isRefreshing ?
                                    Animation.linear(duration: 1.0).repeatForever(autoreverses: false) :
                                    .default,
                                value: isRefreshing,
                            )
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isRefreshing)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showRefreshSuccess)
            }
            .padding()
            .glassEffect()
        } primaryAction: {
            Task {
                await onRefreshRequested()
            }
        }
        .sheet(isPresented: $showingVehicleInfo) {
            NavigationView {
                VehicleInfoView(
                    bbVehicle: bbVehicle,
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") {
                            showingVehicleInfo = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAccountInfo) {
            if let account = vehicleAccount {
                NavigationView {
                    AccountInfoView(
                        account: account,
                    )
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                showingAccountInfo = false
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingHTTPLogs) {
            if let account = vehicleAccount {
                NavigationView {
                    HTTPLogView(accountId: account.id, transition: transition)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") {
                                    showingHTTPLogs = false
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingVehicleConfiguration) {
            if bbVehicle.account?.brandEnum == .fake {
                NavigationView {
                    FakeVehicleDetailView(vehicle: bbVehicle)
                        .navigationTitle("Configure Vehicle")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") {
                                    showingVehicleConfiguration = false
                                }
                            }
                        }
                }
            }
        }
    }
}
