//
//  AddAccountView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct ErrorBox: View {
    let headline: String
    let detail: AttributedString?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.orange.opacity(0.1))
                .stroke(.orange.opacity(0.3), lineWidth: 1)
        }
        .padding(.top, 8)
    }
}

struct AddAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var pin = ""
    @State private var selectedBrand: Brand = .hyundai
    @State private var selectedRegion: Region = .usa
    @State private var isLoading = false
    @State private var errorMessage: String?

    // MFA State
    @State private var mfaState = MFAFlowState()
    @State private var mfaAccount: BBAccount?

    @State private var fakeVehicles: [BBVehicle] = []

    // Focus states for keyboard navigation
    @FocusState private var focusedField: AddAccountField?

    enum AddAccountField: CaseIterable {
        case username, password, pin
    }

    private var availableBrands: [Brand] {
        Brand.availableBrands(for: username, password: password)
    }

    private var isTestAccount: Bool {
        BetterBlueKit.isTestAccount(username: username, password: password)
    }

    var body: some View {
        Form {
            serviceConfigurationSection
            accountInformationSection
            fakeVehicleConfigurationSection

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Add Account")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") {
                    Task {
                        await addAccount()
                    }
                }
                .disabled(
                    username.isEmpty
                        || password.isEmpty
                        || (selectedBrand != .kia
                            && selectedBrand != .fake
                            && pin.isEmpty)
                        || isLoading
                )
            }
        }
        .disabled(isLoading)
        .overlay {
            if isLoading {
                LoadingOverlayView(brandName: selectedBrand.displayName)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .scale(scale: 1.1).combined(with: .opacity),
                    ))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isLoading)
            }
        }
        .mfaFlow(state: mfaState)
        .onAppear {
            focusedField = .username
        }
    }

    // MARK: - Extracted View Sections

    @ViewBuilder
    private var serviceConfigurationSection: some View {
        Section {
            Picker("Brand", selection: $selectedBrand) {
                ForEach(availableBrands, id: \.self) { brand in
                    Text(brand.displayName).tag(brand)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .onChange(of: isTestAccount) { _, newValue in
                if newValue, availableBrands.contains(.fake) {
                    selectedBrand = .fake
                } else if !availableBrands.contains(selectedBrand) {
                    selectedBrand = availableBrands.first ?? .hyundai
                }
            }

            // Only show region picker for non-fake accounts
            if selectedBrand != .fake {
                Picker("Region", selection: $selectedRegion) {
                    ForEach(Region.allCases, id: \.self) { region in
                        Text(region.rawValue).tag(region)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
        } header: {
            Text("Service Configuration")
                    } footer: {
                        if selectedBrand != .fake && selectedRegion != .usa {
                            let regionDetail = try? AttributedString(
                                markdown: "If you'd like to help bring BetterBlue to your region, " +
                                          "please consider [contributing to the open source project]" +
                                          "(https://github.com/schmidtwmark/BetterBlueKit)."
                            )
                            ErrorBox(headline: "Regions other than US are unsupported.", detail: regionDetail)
                        }        }
    }

    @ViewBuilder
    private var accountInformationSection: some View {
        Section {
            HStack {
                Text("Username")
                Spacer()
                TextField("", text: $username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
                    }
            }

            HStack {
                Text("Password")
                Spacer()
                SecureField("", text: $password)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .password)
                    .submitLabel(selectedBrand == .hyundai ? .next : .done)
                    .onSubmit {
                        if selectedBrand == .hyundai {
                            focusedField = .pin
                        } else {
                            Task {
                                await addAccount()
                            }
                        }
                    }
            }

            if selectedBrand == .hyundai {
                HStack {
                    Text("PIN")
                    Spacer()
                    SecureField("", text: $pin)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .pin)
                        .submitLabel(.done)
                        .onSubmit {
                            Task {
                                await addAccount()
                            }
                        }
                }
            }

        } header: {
            Text("Account Information")
        } footer: {
            if selectedBrand == .fake {
                Text("Using test account - fake data will be used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BetterBlue requires an active Hyundai BlueLink or Kia Connect subscription.")
                    Text("BetterBlue stores your credentials securely on your device and in iCloud.")

                    let link = "[GitHub](https://github.com/schmidtwmark/BetterBlue)"
                    if let openSourceString = try? AttributedString(
                        markdown: "BetterBlue is fully open source. To view the source code, visit \(link).") {
                        Text(openSourceString)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fakeVehicleConfigurationSection: some View {
        // Fake Vehicle Configuration Section
        if selectedBrand == .fake {
            FakeVehicleListView(vehicles: $fakeVehicles, accountId: nil)
        }
    }

    private func addAccount() async {
        isLoading = true
        errorMessage = nil

        let bbAccount = BBAccount(
            username: username,
            password: password,
            pin: pin,
            brand: selectedBrand,
            region: selectedRegion
        )

        do {
            try await bbAccount.initialize(modelContext: modelContext)
            // If successful immediately:
            await saveAndFinish(account: bbAccount)
        } catch {
            await MainActor.run {
                if let apiError = error as? APIError {
                    switch apiError.errorType {
                    case .requiresMFA:
                        // Store pending account and start MFA flow
                        self.mfaAccount = bbAccount
                        mfaState.start(from: apiError, account: bbAccount) { [self] in
                            await saveAndFinish(account: bbAccount)
                        } onCancel: { [self] in
                            isLoading = false
                            mfaAccount = nil
                        }
                    case .invalidCredentials:
                        errorMessage = "Invalid username or password. Please check your credentials and try again."
                        isLoading = false
                    case .invalidPin:
                        errorMessage = apiError.message
                        isLoading = false
                    default:
                        errorMessage = "Failed to authenticate: \(apiError.message)"
                        isLoading = false
                    }
                } else {
                    errorMessage = "Failed to authenticate: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func saveAndFinish(account: BBAccount) async {
        do {
            modelContext.insert(account)
            try modelContext.save()

            for fakeVehicle in fakeVehicles {
                fakeVehicle.accountId = account.id
                BBLogger.debug(.app, "AddAccountView: Inserting vehicle \(fakeVehicle.vin)")
                modelContext.insert(fakeVehicle)
                account.vehicles?.append(fakeVehicle)
            }
            try modelContext.save()

            try await account.loadVehicles(modelContext: modelContext)

            await MainActor.run {
                isLoading = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                if let apiError = error as? APIError {
                    errorMessage = "Failed to load vehicles: \(apiError.message)"
                } else {
                    errorMessage = "Failed to load vehicles: \(error.localizedDescription)"
                }
                isLoading = false
            }
        }
    }
}

#Preview("Add Account") {
    NavigationView {
        AddAccountView()
    }
    .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self, BBHTTPLog.self])
}

#Preview("Add Account with Warning") {
    struct PreviewWrapper: View {
        @State private var selectedRegion: Region = .canada
        @State private var selectedBrand: Brand = .hyundai

        var body: some View {
            NavigationView {
                AddAccountView()
            }
            .onAppear {
                // This would show the warning state in the preview
            }
        }
    }

    return PreviewWrapper()
        .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self, BBHTTPLog.self])
}
