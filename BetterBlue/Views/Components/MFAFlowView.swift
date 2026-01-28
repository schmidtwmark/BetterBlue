//
//  MFAFlowView.swift
//  BetterBlue
//
//  Shared MFA (Multi-Factor Authentication) flow components
//

import BetterBlueKit
import SwiftUI

// MARK: - MFA Navigation Path

enum MFANavigationDestination: Hashable {
    case verification
}

// MARK: - MFA Flow State

@MainActor @Observable
final class MFAFlowState {
    var isPresented = false
    var navigationPath = NavigationPath()
    var code = ""
    var xid: String?
    var otpKey: String?
    var email: String?
    var phone: String?
    var notifyType: String?
    var isResendingCode = false
    var isVerifying = false
    var errorMessage: String?

    private var account: BBAccount?
    private var onSuccess: (() async -> Void)?
    private var onCancel: (() -> Void)?

    var canChangeMethod: Bool {
        email != nil && phone != nil
    }

    var deliveryDescription: String {
        if notifyType == "SMS", let phone {
            return "text message to \(phone)"
        } else if notifyType == "EMAIL", let email {
            return "email to \(email)"
        } else {
            return "email or phone"
        }
    }

    /// Start MFA flow from an APIError
    func start(
        from error: APIError,
        account: BBAccount,
        onSuccess: @escaping () async -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        guard let userInfo = error.userInfo else {
            BBLogger.error(.mfa, "MFA error missing userInfo: \(error)")
            return
        }

        self.account = account
        self.onSuccess = onSuccess
        self.onCancel = onCancel

        xid = userInfo["xid"]
        otpKey = userInfo["otpKey"]
        email = userInfo["email"]
        phone = userInfo["phone"]
        code = ""
        errorMessage = nil
        navigationPath = NavigationPath()

        BBLogger.info(.mfa, "MFA flow started - email: \(email ?? "nil"), phone: \(phone ?? "nil")")

        // If only one option, send code directly and show verification
        if phone != nil && email == nil {
            sendCode(notifyType: "SMS", showPickerFirst: false)
        } else if email != nil && phone == nil {
            sendCode(notifyType: "EMAIL", showPickerFirst: false)
        } else if phone != nil || email != nil {
            // Show method picker first
            isPresented = true
        } else {
            BBLogger.error(.mfa, "MFA required but no contact options available")
        }
    }

    func sendCode(notifyType: String, isResend: Bool = false, showPickerFirst: Bool = true) {
        guard let account, let xid, let otpKey else {
            errorMessage = "MFA context missing"
            return
        }

        if isResend {
            isResendingCode = true
        }

        Task {
            do {
                try await account.sendMFA(otpKey: otpKey, xid: xid, notifyType: notifyType)
                self.notifyType = notifyType
                self.isResendingCode = false
                self.errorMessage = nil

                if showPickerFirst {
                    // Navigate from method picker to verification
                    navigationPath.append(MFANavigationDestination.verification)
                } else {
                    // Single option - show sheet and immediately go to verification
                    isPresented = true
                    // Small delay to let sheet appear before navigating
                    try? await Task.sleep(for: .milliseconds(100))
                    navigationPath.append(MFANavigationDestination.verification)
                }
            } catch {
                self.errorMessage = "Failed to send code: \(error.localizedDescription)"
                self.isResendingCode = false
                // If we haven't shown the sheet yet, show it now with the error
                if !isPresented {
                    isPresented = true
                }
            }
        }
    }

    func verify() {
        guard let account, let xid, let otpKey else { return }

        isVerifying = true
        errorMessage = nil

        Task {
            do {
                try await account.verifyMFA(otpKey: otpKey, xid: xid, otp: code)
                isPresented = false
                navigationPath = NavigationPath()
                code = ""
                isVerifying = false
                await onSuccess?()
            } catch {
                isVerifying = false
                if let apiError = error as? APIError {
                    errorMessage = "Verification failed: \(apiError.message)"
                } else {
                    errorMessage = "Verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancel() {
        isPresented = false
        navigationPath = NavigationPath()
        code = ""
        errorMessage = nil
        isVerifying = false
        onCancel?()
    }
}

// MARK: - MFA Flow Sheet Content

struct MFAFlowSheet: View {
    @Bindable var state: MFAFlowState

    var body: some View {
        NavigationStack(path: $state.navigationPath) {
            MFAMethodPickerView(state: state)
                .navigationDestination(for: MFANavigationDestination.self) { destination in
                    switch destination {
                    case .verification:
                        MFAVerificationView(state: state)
                    }
                }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

// MARK: - MFA Method Picker View

struct MFAMethodPickerView: View {
    @Bindable var state: MFAFlowState

    var body: some View {
        Form {
            Section {
                Text("Your Kia account requires verification. Select where to send the code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Verification Required")
            }

            Section {
                if let phone = state.phone {
                    Button {
                        state.sendCode(notifyType: "SMS")
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

                if let email = state.email {
                    Button {
                        state.sendCode(notifyType: "EMAIL")
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

            if let errorMessage = state.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Verify Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    state.cancel()
                }
            }
        }
    }
}

// MARK: - MFA Verification View

struct MFAVerificationView: View {
    @Bindable var state: MFAFlowState
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                Text("Please enter the verification code sent via \(state.deliveryDescription).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Verification Code", text: $state.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFieldFocused)
                    .onSubmit {
                        if !state.code.isEmpty && !state.isVerifying {
                            state.verify()
                        }
                    }
                    .disabled(state.isVerifying)
            } header: {
                Text("Enter Code")
            }

            Section {
                Button {
                    if let notifyType = state.notifyType {
                        state.sendCode(notifyType: notifyType, isResend: true)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Resend Code")
                        if state.isResendingCode {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(state.notifyType == nil || state.isResendingCode || state.isVerifying)
            }

            if let errorMessage = state.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Enter Code")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!state.canChangeMethod)
        .toolbar {
            if !state.canChangeMethod {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        state.cancel()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    state.verify()
                } label: {
                    if state.isVerifying {
                        ProgressView()
                    } else {
                        Text("Verify")
                    }
                }
                .disabled(state.code.isEmpty || state.isVerifying)
            }
        }
        .onAppear {
            codeFieldFocused = true
        }
    }
}

// MARK: - View Modifier for MFA Flow

struct MFAFlowModifier: ViewModifier {
    @Bindable var state: MFAFlowState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.isPresented) {
                MFAFlowSheet(state: state)
            }
    }
}

extension View {
    func mfaFlow(state: MFAFlowState) -> some View {
        modifier(MFAFlowModifier(state: state))
    }
}
