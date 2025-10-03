//
//  DiagnosticInfo.swift
//  BetterBlue
//
//  Created by Claude on 9/17/25.
//

import BetterBlueKit
import CloudKit
import SwiftData
import SwiftUI

struct DiagnosticInfo {
    let timestamp: Date
    let deviceType: String
    let containerURL: String?
    let accountCount: Int
    let vehicleCount: Int
    let hiddenVehicleCount: Int
    let accounts: [AccountDiagnostic]
    let vehicles: [VehicleDiagnostic]
    let cloudKitStatus: CloudKitDiagnostic?

    struct AccountDiagnostic {
        let id: UUID
        let username: String
        let brand: String
        let vehicleCount: Int
    }

    struct VehicleDiagnostic {
        let id: UUID
        let vin: String
        let displayName: String
        let accountId: UUID
        let isHidden: Bool
        let sortOrder: Int
        let lastUpdated: Date?
        let hasEvStatus: Bool
        let hasGasRange: Bool
        let hasLockStatus: Bool
        let hasClimateStatus: Bool
        let hasLocation: Bool
    }

    struct CloudKitDiagnostic {
        let accountStatus: String
        let isSignedIn: Bool
        let isAvailable: Bool
        let containerIdentifier: String?
        let databaseScope: String
        let lastSyncAttempt: Date?
        let syncError: String?
    }

    @MainActor
    static func collect(from context: ModelContext) async -> DiagnosticInfo {
        let allAccounts = (try? context.fetch(FetchDescriptor<BBAccount>())) ?? []
        let allVehicles = (try? context.fetch(FetchDescriptor<BBVehicle>())) ?? []

        let accountDiagnostics = allAccounts.map { account in
            AccountDiagnostic(
                id: account.id,
                username: account.username,
                brand: account.brandEnum.displayName,
                vehicleCount: account.vehicles?.count ?? 0
            )
        }

        let vehicleDiagnostics = allVehicles.map { vehicle in
            VehicleDiagnostic(
                id: vehicle.id,
                vin: vehicle.vin,
                displayName: vehicle.displayName,
                accountId: vehicle.accountId,
                isHidden: vehicle.isHidden,
                sortOrder: vehicle.sortOrder,
                lastUpdated: vehicle.lastUpdated,
                hasEvStatus: vehicle.evStatus != nil,
                hasGasRange: vehicle.gasRange != nil,
                hasLockStatus: vehicle.lockStatus != nil,
                hasClimateStatus: vehicle.climateStatus != nil,
                hasLocation: vehicle.location != nil
            )
        }

        let containerURL: String?
        containerURL = context.container.configurations.first?.url.path

        let cloudKitStatus: CloudKitDiagnostic? = await collectCloudKitStatus(from: context)

        return DiagnosticInfo(
            timestamp: Date(),
            deviceType: getDeviceType(),
            containerURL: containerURL,
            accountCount: allAccounts.count,
            vehicleCount: allVehicles.filter { !$0.isHidden }.count,
            hiddenVehicleCount: allVehicles.filter { $0.isHidden }.count,
            accounts: accountDiagnostics,
            vehicles: vehicleDiagnostics,
            cloudKitStatus: cloudKitStatus
        )
    }

    private static func getDeviceType() -> String {
        #if os(watchOS)
            return "Apple Watch"
        #elseif os(iOS)
            return "iPhone/iPad"
        #else
            return "Unknown"
        #endif
    }

    @MainActor
    private static func collectCloudKitStatus(from _: ModelContext) async -> CloudKitDiagnostic? {
        // Use the BetterBlue CloudKit container identifier
        let containerID = "iCloud.com.markschmidt.BetterBlue"
        let container = CKContainer(identifier: containerID)

        do {
            let accountStatus = try await container.accountStatus()
            let accountStatusString: String
            let isSignedIn: Bool

            switch accountStatus {
            case .available:
                accountStatusString = "Available"
                isSignedIn = true
            case .noAccount:
                accountStatusString = "No Account"
                isSignedIn = false
            case .restricted:
                accountStatusString = "Restricted"
                isSignedIn = false
            case .temporarilyUnavailable:
                accountStatusString = "Temporarily Unavailable"
                isSignedIn = false
            case .couldNotDetermine:
                accountStatusString = "Could Not Determine"
                isSignedIn = false
            @unknown default:
                accountStatusString = "Unknown"
                isSignedIn = false
            }

            return CloudKitDiagnostic(
                accountStatus: accountStatusString,
                isSignedIn: isSignedIn,
                isAvailable: accountStatus == .available,
                containerIdentifier: containerID,
                databaseScope: "Private", // SwiftData uses private database
                lastSyncAttempt: nil, // SwiftData doesn't expose this directly
                syncError: nil // SwiftData doesn't expose this directly
            )
        } catch {
            return CloudKitDiagnostic(
                accountStatus: "Error: \(error.localizedDescription)",
                isSignedIn: false,
                isAvailable: false,
                containerIdentifier: containerID,
                databaseScope: "Private",
                lastSyncAttempt: nil,
                syncError: error.localizedDescription
            )
        }
    }

    var formattedOutput: String {
        var output = """
        Diagnostic Information
        Generated: \(timestamp.formatted())
        Device: \(deviceType)

        Summary:
        • Accounts: \(accountCount)
        • Visible Vehicles: \(vehicleCount)
        • Hidden Vehicles: \(hiddenVehicleCount)
        • Container: \(containerURL ?? "Unknown")

        """

        if let cloudKit = cloudKitStatus {
            output += "\niCloud Status:\n"
            output += "• Account Status: \(cloudKit.accountStatus)\n"
            output += "• Signed In: \(cloudKit.isSignedIn ? "✅" : "❌")\n"
            if let containerID = cloudKit.containerIdentifier {
                output += "• Container: \(containerID)\n"
            }
            output += "• Database: \(cloudKit.databaseScope)\n"
            if let syncError = cloudKit.syncError {
                output += "• Sync Error: \(syncError)\n"
            }
            output += "\n"
        } else {
            output += "\niCloud Status: Not configured for CloudKit sync\n\n"
        }

        if !accounts.isEmpty {
            output += "\nAccounts:\n"
            for account in accounts {
                output += "• \(account.username) (\(account.brand))\n"
                output += "  ID: \(account.id.uuidString.prefix(8))...\n"
                output += "  Vehicles: \(account.vehicleCount)\n"
                output += "\n"
            }
        }

        if !vehicles.isEmpty {
            output += "\nVehicles:\n"
            for vehicle in vehicles {
                output += "• \(vehicle.displayName) (\(vehicle.vin))\n"
                output += "  ID: \(vehicle.id.uuidString.prefix(8))...\n"
                output += "  Account: \(vehicle.accountId.uuidString.prefix(8))...\n"
                output += "  Hidden: \(vehicle.isHidden ? "Yes" : "No")\n"
                output += "  Sort Order: \(vehicle.sortOrder)\n"
                if let lastUpdated = vehicle.lastUpdated {
                    output += "  Last Updated: \(lastUpdated.formatted())\n"
                } else {
                    output += "  Last Updated: Never\n"
                }
                output += "  Status Data:\n"
                output += "    EV: \(vehicle.hasEvStatus ? "✅" : "❌")\n"
                output += "    Gas: \(vehicle.hasGasRange ? "✅" : "❌")\n"
                output += "    Lock: \(vehicle.hasLockStatus ? "✅" : "❌")\n"
                output += "    Climate: \(vehicle.hasClimateStatus ? "✅" : "❌")\n"
                output += "    Location: \(vehicle.hasLocation ? "✅" : "❌")\n"
                output += "\n"
            }
        }

        return output
    }
}

struct DiagnosticInfoView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var diagnosticInfo: DiagnosticInfo?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView("Collecting diagnostics...")
                        .padding()
                }
            } else if let diagnosticInfo = diagnosticInfo {
                List {
                    summarySection(diagnosticInfo)

                    if let cloudKit = diagnosticInfo.cloudKitStatus {
                        cloudKitSection(cloudKit)
                    }

                    if !diagnosticInfo.accounts.isEmpty {
                        accountsSection(diagnosticInfo.accounts)
                    }

                    if !diagnosticInfo.vehicles.isEmpty {
                        ForEach(diagnosticInfo.vehicles.indices, id: \.self) { index in
                            vehicleSection(diagnosticInfo.vehicles[index])
                        }
                    }
                }
                #if os(watchOS)
                .listStyle(.automatic)
                #else
                .listStyle(.insetGrouped)
                #endif
            } else {
                VStack {
                    Text("Failed to collect diagnostic information")
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Sync Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let diagnosticInfo = diagnosticInfo {
                #if !os(watchOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareLink(
                            item: diagnosticInfo.formattedOutput,
                            subject: Text("BetterBlue Sync Diagnostics"),
                            message: Text("Diagnostic information from BetterBlue app")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                #endif
            }
        }
        .task {
            await loadDiagnostics()
        }
    }

    @ViewBuilder
    private func summarySection(_ info: DiagnosticInfo) -> some View {
        Section {
            diagnosticRow("Generated", info.timestamp.formatted())
            diagnosticRow("Device", info.deviceType)
            diagnosticRow("Accounts", "\(info.accountCount)")
            diagnosticRow("Visible Vehicles", "\(info.vehicleCount)")
            diagnosticRow("Hidden Vehicles", "\(info.hiddenVehicleCount)")
            diagnosticRow("Container", info.containerURL ?? "Unknown")
        } header: {
            Text("Summary")
        }
    }

    @ViewBuilder
    private func cloudKitSection(_ cloudKit: DiagnosticInfo.CloudKitDiagnostic) -> some View {
        Section {
            diagnosticRow("Account Status", cloudKit.accountStatus)
            diagnosticRow("Signed In", cloudKit.isSignedIn ? "✅ Yes" : "❌ No")
            diagnosticRow("Available", cloudKit.isAvailable ? "✅ Yes" : "❌ No")
            if let containerID = cloudKit.containerIdentifier {
                diagnosticRow("Container", containerID)
            }
            diagnosticRow("Database", cloudKit.databaseScope)
            if let syncError = cloudKit.syncError {
                diagnosticRow("Sync Error", syncError)
            }
        } header: {
            Text("iCloud Status")
        }
    }

    @ViewBuilder
    private func accountsSection(_ accounts: [DiagnosticInfo.AccountDiagnostic]) -> some View {
        Section {
            ForEach(accounts.indices, id: \.self) { index in
                let account = accounts[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(account.username) (\(account.brand))")
                        .font(.headline)
                    Text("ID: \(account.id.uuidString.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Vehicles: \(account.vehicleCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Accounts")
        }
    }

    @ViewBuilder
    private func vehicleSection(_ vehicle: DiagnosticInfo.VehicleDiagnostic) -> some View {
        Section {
            diagnosticRow("VIN", vehicle.vin)
            diagnosticRow("ID", "\(vehicle.id.uuidString.prefix(8))...")
            diagnosticRow("Account", "\(vehicle.accountId.uuidString.prefix(8))...")
            diagnosticRow("Hidden", vehicle.isHidden ? "Yes" : "No")
            diagnosticRow("Sort Order", "\(vehicle.sortOrder)")

            if let lastUpdated = vehicle.lastUpdated {
                diagnosticRow("Last Updated", lastUpdated.formatted())
            } else {
                diagnosticRow("Last Updated", "Never")
            }

            diagnosticRow("EV Status", vehicle.hasEvStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Gas Range", vehicle.hasGasRange ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Lock Status", vehicle.hasLockStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Climate Status", vehicle.hasClimateStatus ? "✅ Available" : "❌ Not Available")
            diagnosticRow("Location", vehicle.hasLocation ? "✅ Available" : "❌ Not Available")
        } header: {
            Text(vehicle.displayName)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
            #if !os(watchOS)
                .textSelection(.enabled)
            #endif
        }
    }

    private func loadDiagnostics() async {
        isLoading = true
        diagnosticInfo = await DiagnosticInfo.collect(from: modelContext)
        isLoading = false
    }
}
