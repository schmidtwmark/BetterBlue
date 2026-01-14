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

// swiftlint:disable:this type_body_length file_length
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
    @State private var showingMFAMethodPicker = false
    @State private var showingMFA = false
    @State private var mfaCode = ""
    @State private var mfaXID: String?
    @State private var mfaOTPKey: String?
    @State private var mfaAccount: BBAccount?
    @State private var mfaHasEmail = false
    @State private var mfaHasPhone = false
    @State private var mfaEmail: String?
    @State private var mfaPhone: String?

    @State private var fakeVehicles: [BBVehicle] = []

    // Focus states for keyboard navigation
    @FocusState private var focusedField: AddAccountField?

    enum AddAccountField: CaseIterable {
        case username, password, pin, mfaCode
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
        .sheet(isPresented: $showingMFAMethodPicker) {
            mfaMethodPickerSheet
        }
        .sheet(isPresented: $showingMFA) {
            mfaSheet
        }
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
                        if selectedBrand == .kia {
                           let kiaDetail = try? AttributedString(
                               markdown: "Kia made changes to their API that breaks compatibility with " +
                                         "BetterBlueKit and other third-party apps. See [this GitHub issue]" +
                                         "(https://github.com/schmidtwmark/BetterBlueKit/issues/7) for more details."
                           )
                           ErrorBox(headline: "Kia currently unsupported", detail: kiaDetail)
                        } else if selectedBrand != .fake && selectedRegion != .usa {
                            let regionDetail = try? AttributedString(
                                markdown: "If you'd like to help bring BetterBlue to your region, " +
                                          "please consider [contributing to the open source project]\n" +
                                          "(https://github.com/schmidtwmark/BetterBlueKit)."
                            )
                            ErrorBox(headline: "Regions other than US are untested and are unlikely to work correctly.", detail: regionDetail)
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

    @ViewBuilder
    private var mfaMethodPickerSheet: some View {
        NavigationView {
            Form {
                Section {
                    Text("Choose how you'd like to receive your verification code.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Verification Required")
                }

                Section {
                    if mfaHasPhone, let phone = mfaPhone {
                        Button {
                            showingMFAMethodPicker = false
                            sendMFACode(notifyType: "SMS")
                        } label: {
                            HStack {
                                Image(systemName: "message.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading) {
                                    Text("Text Message (SMS)")
                                        .foregroundColor(.primary)
                                    Text(phone)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    if mfaHasEmail, let email = mfaEmail {
                        Button {
                            showingMFAMethodPicker = false
                            sendMFACode(notifyType: "EMAIL")
                        } label: {
                            HStack {
                                Image(systemName: "envelope.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text("Email")
                                        .foregroundColor(.primary)
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Send Code To")
                }
            }
            .navigationTitle("Verify Identity")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingMFAMethodPicker = false
                        isLoading = false
                        mfaAccount = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var mfaSheet: some View {
        NavigationView {
            Form {
                Section {
                    Text(
                        "Please enter the verification code sent to your " +
                            "email or phone."
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("Verification Code", text: $mfaCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focusedField, equals: .mfaCode)
                        .onSubmit {
                            Task {
                                await verifyMFA()
                            }
                        }
                } header: {
                    Text("Verification Required")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Enter Code")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingMFA = false
                        isLoading = false
                        mfaAccount = nil // Discard pending account
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Verify") {
                        Task {
                            await verifyMFA()
                        }
                    }
                    .disabled(mfaCode.isEmpty || isLoading)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
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
                        // MFA Required - Extract info and show method picker
                        if let xid = apiError.userInfo?["xid"],
                           let otpKey = apiError.userInfo?["otpKey"] {
                            self.mfaXID = xid
                            self.mfaOTPKey = otpKey
                            self.mfaAccount = bbAccount
                            self.mfaHasEmail = apiError.userInfo?["hasEmail"] == "true"
                            self.mfaHasPhone = apiError.userInfo?["hasPhone"] == "true"
                            self.mfaEmail = apiError.userInfo?["email"]
                            self.mfaPhone = apiError.userInfo?["phone"]

                            // If only one option, use it directly
                            if mfaHasPhone && !mfaHasEmail {
                                sendMFACode(notifyType: "SMS")
                            } else if mfaHasEmail && !mfaHasPhone {
                                sendMFACode(notifyType: "EMAIL")
                            } else if mfaHasPhone || mfaHasEmail {
                                // Show picker
                                showingMFAMethodPicker = true
                            } else {
                                errorMessage = "MFA required but no delivery method available."
                                isLoading = false
                            }
                        } else {
                            errorMessage = "MFA required but missing context."
                            isLoading = false
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

    private func sendMFACode(notifyType: String) {
        guard let account = mfaAccount, let xid = mfaXID, let otpKey = mfaOTPKey else {
            errorMessage = "MFA context missing"
            isLoading = false
            return
        }

        print("💡 [AddAccountView] sendMFACode called with notifyType: \(notifyType)")
        Task {
            do {
                try await account.sendMFA(otpKey: otpKey, xid: xid, notifyType: notifyType)
                print("💡 [AddAccountView] account.sendMFA successful")
                await MainActor.run {
                    self.showingMFA = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to send MFA code: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func verifyMFA() async {
        guard let account = mfaAccount, let xid = mfaXID, let otpKey = mfaOTPKey else { return }

        do {
            try await account.verifyMFA(otpKey: otpKey, xid: xid, otp: mfaCode)
            await MainActor.run {
                showingMFA = false
            }
            // Now finish up
            await saveAndFinish(account: account)
        } catch {
            await MainActor.run {
                if let apiError = error as? APIError {
                    errorMessage = "Verification failed: \(apiError.message)"
                } else {
                    errorMessage = "Verification failed: \(error.localizedDescription)"
                }
                // Don't close sheet, let user try again
            }
        }
    }

    private func saveAndFinish(account: BBAccount) async {
        do {
            modelContext.insert(account)
            try modelContext.save()

            for fakeVehicle in fakeVehicles {
                fakeVehicle.accountId = account.id
                print("Inserting vehicle \(fakeVehicle.vin)")
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
