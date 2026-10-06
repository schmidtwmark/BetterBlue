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
    /// State + .sheet modifiers live on `MainView` so they survive
    /// brief scenePhase flips (Password autofill, screenshot capture)
    /// that tear down this view through the 0xdead10cc guard. The
    /// view here only owns the buttons that *trigger* the sheets.
    @Binding var showingAddAccount: Bool
    @Binding var showingTroubleshooting: Bool

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

            Button {
                showingTroubleshooting = true
            } label: {
                Label("Trouble signing in?", systemImage: "questionmark.circle")
                    .font(.callout)
                    .expandedTapTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding()
    }
}

struct EmptyVehiclesView: View {
    @Binding var isLoading: Bool
    @Binding var lastError: APIError?
    /// Reloads every account's vehicles — what "Try Again" runs.
    /// `MainView` owns the load, which also drives `isLoading` and
    /// `lastError`: both are reset as it starts, so the error and
    /// this button give way to the spinner until it finishes.
    let onRetry: () async -> Void

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
                ErrorDetailsView(
                    error: ActionError(action: "Load vehicles", error: error)
                )
                .padding(.horizontal)

                Button("Try Again") {
                    Task { await onRetry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
