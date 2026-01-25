//
//  VehicleCardView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 7/14/25.
//

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleCardView: View {
    @State var bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    let accounts: [BBAccount]
    let onVehicleSelected: (BBVehicle) -> Void
    let onSuccessfulRefresh: (() -> Void)?
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Namespace private var fallbackTransition
    @State private var isRefreshing = false
    @State private var showRefreshSuccess = false
    @State private var errorMessage: AttributedString?
    @State private var lastAPIError: APIError?
    @State private var showingErrorHTTPLogs = false
    @State private var refreshTask: Task<Void, Never>?

    // Safe accessor for evStatus
    private var safeEvStatus: VehicleStatus.EVStatus? {
        // Check if the vehicle is properly attached to a context before accessing properties
        guard bbVehicle.modelContext != nil else {
            BBLogger.warning(.app, "VehicleCardView: BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.evStatus
    }

    // Safe accessor for gasRange
    private var safeGasRange: VehicleStatus.FuelRange? {
        // Check if the vehicle is properly attached to a context before accessing properties
        guard bbVehicle.modelContext != nil else {
            BBLogger.warning(.app, "VehicleCardView: BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.gasRange
    }

    // Safe accessor for location
    private var safeLocation: VehicleStatus.Location? {
        // Check if the vehicle is properly attached to a context before accessing properties
        guard bbVehicle.modelContext != nil else {
            BBLogger.warning(.app, "VehicleCardView: BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.location
    }

    var body: some View {
        VStack(spacing: 8) {
            // Error message card (only show if there's an error)
            if let errorMessage {
                Group {
                    if AppSettings.shared.debugModeEnabled {
                        HStack {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .tint(.blue)
                            Spacer()
                        }
                    } else {
                        Button {
                            if lastAPIError != nil {
                                showingErrorHTTPLogs = true
                            }
                        } label: {
                            HStack {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
                .vehicleCardGlassEffect()
            }

            VehicleTitleView(
                bbVehicle: bbVehicle,
                bbVehicles: bbVehicles,
                onVehicleSelected: onVehicleSelected,
                accounts: accounts,
                transition: transition
            )

            // Vehicle status info
            // EV Range Display (if available)
            if let evStatus = safeEvStatus {
                EVRangeDisplayCard(evStatus: evStatus)
            }

            // Charging Control Button (if EV)
            if safeEvStatus != nil {
                ChargingButton(bbVehicle: bbVehicle, transition: transition)
            }

            // Gas Range Card (if available)
            if let gasRange = safeGasRange {
                GasRangeCardView(gasRange: gasRange)
            }

            // Controls Row - Lock and Climate buttons side by side
            LockButton(bbVehicle: bbVehicle, transition: transition)
            ClimateButton(bbVehicle: bbVehicle, transition: transition)
        }
        .padding(.horizontal)
        .task {
            await refreshStatus()
        }
        .onAppear {
            // Kick off refresh whenever the view appears
            Task {
                await refreshStatus()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
        }
        .sheet(isPresented: $showingErrorHTTPLogs) {
            if let account = bbVehicle.account {
                NavigationView {
                    HTTPLogView(accountId: account.id, transition: transition)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Done") {
                                    showingErrorHTTPLogs = false
                                }
                            }
                        }
                }
            }
        }
    }

    private func refreshStatus() async {
        // Cancel any existing refresh task
        if let task = refreshTask {
            return await task.value
        }

        refreshTask = Task {
            await performRefresh()
        }

        await refreshTask?.value
        refreshTask = nil
    }

    private func performRefresh() async {
        // Clear any pending status waiters before starting refresh
        await bbVehicle.clearPendingStatusWaiters()

        await MainActor.run {
            isRefreshing = true
            showRefreshSuccess = false
            errorMessage = nil
            lastAPIError = nil
        }

        do {
            guard let account = bbVehicle.account else {
                throw APIError(message: "Account not found for vehicle")
            }

            try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: modelContext)
            // Check if task was cancelled
            if Task.isCancelled {
                await MainActor.run {
                    isRefreshing = false
                }
                return
            }

            await MainActor.run {
                errorMessage = nil
                isRefreshing = false
                showRefreshSuccess = true

                // Refresh widgets when vehicle status is updated
                WidgetCenter.shared.reloadTimelines(ofKind: "BetterBlueWidget")

                // Notify parent that refresh was successful (clears global error)
                onSuccessfulRefresh?()

                // Hide success indicator after 2 seconds
                Task {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    await MainActor.run {
                        showRefreshSuccess = false
                    }
                }
            }
        } catch {
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = false

                // Only show error if it's not a cancellation
                if !Task.isCancelled, !(error is CancellationError) {
                    BBLogger.error(.app, "VehicleCardView: Error fetching vehicle status for \(bbVehicle.vin): \(error)")
                    handleError(error)
                }
            }
        }
    }

    private func handleError(_ error: Error) {
        if let apiError = error as? APIError {
            lastAPIError = apiError
            let message = getUserFriendlyErrorMessage(for: apiError)
            if let attributed = try? AttributedString(markdown: message) {
                errorMessage = attributed
            } else {
                errorMessage = AttributedString(message)
            }
        } else {
            lastAPIError = nil
            errorMessage = AttributedString("Failed to refresh: \(error.localizedDescription)")
        }
        BBLogger.debug(.app, "VehicleCardView: Detailed error for vehicle \(bbVehicle.vin): \(error)")
    }

    fileprivate func getUserFriendlyErrorMessageForGeneralError(_ error: APIError) -> String {
        // For general errors, provide context based on common scenarios
        if error.message.contains("timeout") || error.message.contains("timed out") {
            "Vehicle not responding - try again later"
        } else if error.message.contains("network") || error.message.contains("Network") {
            "Network connection issue - check your internet"
        } else if error.message.contains("404") {
            "Vehicle not found on server"
        } else if error.message.contains("500") || error.message.contains("502") || error.message.contains("503") {
            "Server temporarily unavailable - try again later"
        } else if error.code != nil, error.code! >= 400 {
            "Server error (\(error.code!)) - try again later"
        } else {
            "Unable to refresh - check connection and try again"
        }
    }

    private func getUserFriendlyErrorMessage(for error: APIError) -> String {
        switch error.errorType {
        case .invalidCredentials:
            "Login expired - please check account settings"
        case .invalidPin:
            "PIN validation failed - check account settings"
        case .invalidVehicleSession:
            "Vehicle session expired - trying to reconnect"
        case .serverError:
            "Server temporarily unavailable - try again later"
        case .concurrentRequest:
            "Another request in progress - please wait and try again"
        case .failedRetryLogin:
            "Unable to reconnect - check account settings"
        case .requiresMFA:
            "MFA Required - Please re-authenticate in Settings"
        case .general:
            getUserFriendlyErrorMessageForGeneralError(error)
        case .kiaInvalidRequest:
            error.message
        }
    }
}

#Preview {
    Text("VehicleCardView Preview")
}
