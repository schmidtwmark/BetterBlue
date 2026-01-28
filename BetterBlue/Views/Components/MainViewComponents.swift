//
//  MainViewComponents.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftUI

struct EmptyAccountsView: View {
    let transition: Namespace.ID
    @State private var showingAddAccount = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "car.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Accounts")
                .font(.title)
                .fontWeight(.bold)

            Text("Add an account to get started")
                .foregroundColor(.secondary)

            Button("Add Account") {
                showingAddAccount = true
            }
            .buttonStyle(.borderedProminent)
            .matchedTransitionSource(
                id: "add-account",
                in: transition,
            )
        }
        .padding()
        .sheet(isPresented: $showingAddAccount) {
            NavigationView {
                AddAccountView()
                    .toolbar {
                        ToolbarItem(
                            placement: .topBarLeading,
                            content: {
                                Button {
                                    showingAddAccount = false
                                } label: {
                                    Text("Cancel")
                                }
                            },
                        )
                    }
            }
            .navigationTransition(
                .zoom(sourceID: "add-account", in: transition),
            )
        }
    }
}

struct EmptyVehiclesView: View {
    @Binding var isLoading: Bool
    @Binding var lastError: APIError?

    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading vehicles...")
                    .foregroundColor(.secondary)
            } else {
                Image(
                    systemName: lastError != nil ?
                        "exclamationmark.triangle" : "car.fill",
                )
                .font(.system(size: 60))
                .foregroundColor(
                    lastError != nil ? .red : .secondary,
                )

                Text(
                    lastError != nil ? "Connection Error" : "No Vehicles",
                )
                .font(.title)
                .fontWeight(.bold)
            }

            if let error = lastError {
                Text(error.message)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()

                Button("Try Again") {
                    Task {
                        // Would need to pass this up somehow
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct VehicleCardsView: View {
    let displayedVehicles: [BBVehicle]
    let accounts: [BBAccount]
    @Binding var selectedVehicleIndex: Int
    let onSuccessfulRefresh: (() -> Void)?
    @State private var scrollPosition: Int? = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(
                        Array(displayedVehicles.enumerated()),
                        id: \.element.id,
                    ) { index, bbVehicle in
                        VehicleCardView(
                            bbVehicle: bbVehicle,
                            bbVehicles: displayedVehicles,
                            accounts: accounts,
                            onVehicleSelected: { selectedVehicle in
                                if let newIndex = displayedVehicles.firstIndex(where: {
                                    $0.vin == selectedVehicle.vin
                                }) {
                                    selectedVehicleIndex = newIndex
                                }
                            },
                            onSuccessfulRefresh: onSuccessfulRefresh,
                        )
                        .frame(maxWidth: 600)
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition)
            .scrollClipDisabled()
            .onChange(of: scrollPosition) { _, newValue in
                if let newValue {
                    selectedVehicleIndex = newValue
                }
            }
            .onChange(of: selectedVehicleIndex) { _, newValue in
                if scrollPosition != newValue {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollPosition = newValue
                    }
                }
            }
            .onAppear {
                scrollPosition = selectedVehicleIndex
            }
            .background(Color.clear) // Explicit clear background
            .allowsHitTesting(true) // Only allow hits on actual content

            if displayedVehicles.count > 1 {
                PageIndicators(
                    currentPage: selectedVehicleIndex,
                    totalPages: displayedVehicles.count,
                )
                .padding(.top, 10)
            }
        }
        .background(Color.clear) // Ensure the whole VStack has clear background
    }
}

struct PageIndicators: View {
    let currentPage: Int
    let totalPages: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< totalPages, id: \.self) { index in
                Circle()
                    .fill(
                        index == currentPage ?
                            Color.primary : Color.secondary.opacity(0.5),
                    )
                    .frame(width: 8, height: 8)
            }
        }
    }
}
