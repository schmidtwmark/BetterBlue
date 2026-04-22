//
//  AccountInfoView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/7/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct AccountInfoView: View {
    let account: BBAccount
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword: String = ""
    @State private var newPin: String = ""
    @State private var isLoading = false
    /// Set when a save attempt fails so the form can render a full
    /// `ErrorDetailsView`. Cleared before each attempt and on success.
    @State private var saveError: ActionError?
    @State private var successMessage: String?
    @State private var showingPasswordDialog = false
    @State private var showingPinDialog = false
    @State private var fakeVehicles: [BBVehicle] = []
    @Namespace private var fallbackTransition

    private var hasPasswordChanges: Bool {
        !newPassword.isEmpty
    }

    private var hasPinChanges: Bool {
        !newPin.isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Username")
                    Spacer()
                    Text(account.username)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Brand")
                    Spacer()
                    Text(account.brandEnum.displayName)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Region")
                    Spacer()
                    Text(account.regionEnum.rawValue)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Account Info")
            }

            Section {
                Button("Change Password") {
                    newPassword = ""
                    showingPasswordDialog = true
                }
                .matchedTransitionSource(
                    id: "change-password",
                    in: transition ?? fallbackTransition,
                )

                if account.brandEnum != .kia, account.brandEnum != .fake {
                    Button("Change PIN") {
                        newPin = ""
                        showingPinDialog = true
                    }
                    .matchedTransitionSource(
                        id: "change-pin",
                        in: transition ?? fallbackTransition,
                    )
                }
            } header: {
                Text("Credentials")
            }

            if AppSettings.shared.debugModeEnabled {
                Section {
                    NavigationLink("View HTTP Logs", destination: HTTPLogView(accountId: account.id))
                } header: {
                    Text("Debugging")
                }
            }

            // Fake vehicle management for fake accounts
            if account.brandEnum == .fake {
                FakeVehicleListView(vehicles: $fakeVehicles, accountId: account.id)
            }

            // Hidden vehicles section
            let hiddenVehicles = account.safeVehicles.filter(\.isHidden)
            if !hiddenVehicles.isEmpty {
                Section {
                    ForEach(hiddenVehicles, id: \.id) { bbVehicle in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bbVehicle.displayName)
                                    .font(.headline)
                                Text("VIN: \(bbVehicle.vin)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Show") {
                                bbVehicle.isHidden = false
                                do {
                                    try modelContext.save()
                                } catch {
                                    BBLogger.error(.app, "Failed to show vehicle: \(error)")
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("Hidden Vehicles")
                }
            }

            // Show success/error messages from credential changes
            if let successMessage {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(successMessage)
                            .foregroundColor(.green)
                    }
                }
            } else if let saveError {
                Section {
                    ErrorDetailsView(error: saveError)
                }
            }
        }
        .navigationTitle("Account Info")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isLoading)
        .overlay {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .alert("Change Password", isPresented: $showingPasswordDialog) {
            SecureField("New Password", text: $newPassword)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    await savePassword()
                }
            }
            .disabled(newPassword.isEmpty)
        }
        .alert("Change PIN", isPresented: $showingPinDialog) {
            SecureField("New PIN", text: $newPin)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    await savePin()
                }
            }
            .disabled(newPin.isEmpty)
        }
        .onAppear {
            fakeVehicles = account.safeVehicles
        }
    }

    private func savePassword() async {
        guard !newPassword.isEmpty else { return }

        isLoading = true
        saveError = nil

        do {
            // We don't need to create a new Account struct, just test authentication

            // Test the new credentials by trying to authenticate
            let testAccount = BBAccount(
                username: account.username,
                password: newPassword,
                pin: account.pin,
                brand: account.brandEnum,
                region: account.regionEnum,
            )
            try await testAccount.initialize(modelContext: modelContext)

            // If successful, update the account
            await MainActor.run {
                BBAccount.updateAccount(account, password: newPassword, pin: account.pin, modelContext: modelContext)
                newPassword = ""
                isLoading = false
                saveError = nil
                successMessage = "Password updated successfully"
                showingPasswordDialog = false

                // Auto-dismiss success message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    successMessage = nil
                }
            }

        } catch {
            await MainActor.run {
                saveError = ActionError(
                    action: "Update password",
                    error: error,
                    accountId: account.id
                )
                isLoading = false
                successMessage = nil
            }
        }
    }

    private func savePin() async {
        guard !newPin.isEmpty else { return }

        isLoading = true
        saveError = nil

        do {
            // We don't need to create a new Account struct, just test authentication

            // Test the new credentials by trying to authenticate
            let testAccount = BBAccount(
                username: account.username,
                password: account.password,
                pin: newPin,
                brand: account.brandEnum,
                region: account.regionEnum,
            )
            try await testAccount.initialize(modelContext: modelContext)

            // If successful, update the account
            await MainActor.run {
                BBAccount.updateAccount(account, password: account.password, pin: newPin, modelContext: modelContext)
                newPin = ""
                isLoading = false
                saveError = nil
                successMessage = "PIN updated successfully"
                showingPinDialog = false

                // Auto-dismiss success message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    successMessage = nil
                }
            }

        } catch {
            await MainActor.run {
                saveError = ActionError(
                    action: "Update PIN",
                    error: error,
                    accountId: account.id
                )
                isLoading = false
                successMessage = nil
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            let testAccount = BBAccount(
                username: "test@example.com",
                password: "password",
                pin: "1234",
                brand: .hyundai,
                region: .usa
            )

            NavigationView {
                AccountInfoView(account: testAccount)
            }
            .modelContainer(for: [BBAccount.self, BBVehicle.self])
        }
    }
    return PreviewWrapper()
}
