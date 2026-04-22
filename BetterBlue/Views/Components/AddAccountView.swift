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
    let backgroundColor: Color
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(backgroundColor)

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
                .fill(backgroundColor.opacity(0.1))
                .stroke(backgroundColor.opacity(0.3), lineWidth: 1)
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
    /// Populated when login or first vehicle-load fails so the form can
    /// render a full `ErrorDetailsView` (headline + summary + technical
    /// details collapsed by default).
    @State private var saveError: ActionError?

    // MFA State
    @State private var mfaState = MFAFlowState()
    @State private var mfaAccount: BBAccount?

    @State private var fakeVehicles: [BBVehicle] = []

    /// Debug-only: force the fake-account creation to fail so the
    /// `ErrorDetailsView` card on this screen can be previewed without
    /// needing a real Hyundai/Kia outage. Shown as a toggle under the
    /// fake-vehicle configuration section when the fake brand is
    /// selected.
    @State private var simulateLoginFailure: Bool = false

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
            debugFailureSection

            if let saveError {
                Section {
                    ErrorDetailsView(error: saveError)
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
            .onChange(of: selectedBrand) { _, newValue in
                if newValue == .fake && username.isEmpty && password.isEmpty {
                    username = "fake-\(UUID().uuidString.prefix(8).lowercased())@betterblue.com"
                    password = "betterblue"
                }
            }

            // Only show region picker for non-fake accounts
            if selectedBrand != .fake {
                Picker("Region", selection: $selectedRegion) {
                    ForEach(Region.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
        } header: {
            Text("Service Configuration")
                    } footer: {
                        if betaRegions(for: selectedBrand).contains(selectedRegion) {
                            let regionDetail = try? AttributedString(markdown: "If you experience issues, please report them on the [Github page](https://github.com/schmidtwmark/BetterBlueKit).")
                            ErrorBox(headline: "\(selectedBrand.displayName) \(selectedRegion.displayName) is in BETA", detail: regionDetail, backgroundColor: .blue, icon: "hammer.circle")
                        } else if !supportedRegions(for: selectedBrand).contains(selectedRegion) {
                            let regionDetail = try? AttributedString(
                                markdown: "If you'd like to help bring BetterBlue to your region, " +
                                          "please consider [contributing to the open source project]" +
                                          "(https://github.com/schmidtwmark/BetterBlueKit)."
                            )
                            ErrorBox(headline: "\(selectedBrand.displayName) \(selectedRegion.displayName) is unsupported.", detail: regionDetail, backgroundColor: .orange, icon: "exclamationmark.triangle")
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

    /// Shown only for the fake brand (or when the current credentials
    /// pattern-match the test account). Toggle simulates the login
    /// throwing, so the on-screen `ErrorDetailsView` card can be
    /// previewed without needing real API credentials.
    @ViewBuilder
    private var debugFailureSection: some View {
        if selectedBrand == .fake || isTestAccount {
            Section {
                Toggle("Fail Account Creation", isOn: $simulateLoginFailure)
            } header: {
                Text("Debug")
            } footer: {
                Text("When on, tapping Add throws an `invalidCredentials` error before the fake client runs. Use this to preview the error card on this screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addAccount() async {
        isLoading = true
        saveError = nil

        let bbAccount = BBAccount(
            username: username,
            password: password,
            pin: pin,
            brand: selectedBrand,
            region: selectedRegion
        )

        // Debug short-circuit: throw before we even hit the fake client so
        // the error-details card on this screen renders against a known
        // error shape. Only available for the fake brand (or test
        // credentials) — no way to reach this for real Hyundai/Kia sign-in.
        if simulateLoginFailure, selectedBrand == .fake || isTestAccount {
            await MainActor.run {
                saveError = ActionError(
                    action: "Sign in to \(selectedBrand.displayName)",
                    error: APIError.invalidCredentials(
                        "Simulated account-creation failure (debug toggle on).",
                        apiName: "FakeAPI"
                    ),
                    accountId: bbAccount.id
                )
                isLoading = false
            }
            return
        }

        do {
            try await bbAccount.initialize(modelContext: modelContext)
            // If successful immediately:
            await saveAndFinish(account: bbAccount)
        } catch {
            await MainActor.run {
                // MFA is handled out-of-band via the MFA sheet, not as an
                // error — keep that branch separate so we don't render
                // "Sign in failed" while the verification prompt is open.
                if let apiError = error as? APIError, apiError.errorType == .requiresMFA {
                    self.mfaAccount = bbAccount
                    mfaState.start(from: apiError, account: bbAccount) { [self] in
                        await saveAndFinish(account: bbAccount)
                    } onCancel: { [self] in
                        isLoading = false
                        mfaAccount = nil
                    }
                    return
                }

                saveError = ActionError(
                    action: "Sign in to \(selectedBrand.displayName)",
                    error: error,
                    accountId: bbAccount.id
                )
                isLoading = false
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
                saveError = ActionError(
                    action: "Load vehicles",
                    error: error,
                    accountId: account.id
                )
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
