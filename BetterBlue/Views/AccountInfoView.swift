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
    @State private var errorMessage: String?
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
                                    print("Failed to show vehicle: \(error)")
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
            } else if let errorMessage {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
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
        errorMessage = nil

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
                errorMessage = nil
                successMessage = "Password updated successfully"
                showingPasswordDialog = false

                // Auto-dismiss success message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    successMessage = nil
                }
            }

        } catch {
            await MainActor.run {
                if let apiError = error as? APIError {
                    switch apiError.errorType {
                    case .invalidCredentials:
                        errorMessage = "Invalid password. Please check your password and try again."
                    case .invalidPin:
                        errorMessage = apiError.message
                    default:
                        errorMessage = "Failed to verify password: \(apiError.message)"
                    }
                } else {
                    errorMessage = "Failed to verify password: \(error.localizedDescription)"
                }
                isLoading = false
                successMessage = nil
            }
        }
    }

    private func savePin() async {
        guard !newPin.isEmpty else { return }

        isLoading = true
        errorMessage = nil

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
                errorMessage = nil
                successMessage = "PIN updated successfully"
                showingPinDialog = false

                // Auto-dismiss success message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    successMessage = nil
                }
            }

        } catch {
            await MainActor.run {
                if let apiError = error as? APIError {
                    switch apiError.errorType {
                    case .invalidCredentials:
                        errorMessage = "Invalid PIN. Please check your PIN and try again."
                    case .invalidPin:
                        errorMessage = apiError.message
                    default:
                        errorMessage = "Failed to verify PIN: \(apiError.message)"
                    }
                } else {
                    errorMessage = "Failed to verify PIN: \(error.localizedDescription)"
                }
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
