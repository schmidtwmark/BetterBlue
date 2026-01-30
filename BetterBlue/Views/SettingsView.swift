//
//  SettingsView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 7/14/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [BBAccount]
    @Query(
        filter: #Predicate<BBVehicle> { $0.isHidden == false },
        sort: \BBVehicle.sortOrder,
    ) private var displayedVehicles: [BBVehicle]
    @Environment(\.dismiss) private var dismiss
    @State private var appSettings = AppSettings.shared

    // Debug functionality - only in debug builds
    @State private var showingClearDataAlert = false
    @State private var clearDataResult: String?
    @State private var showingLiveActivitiesInfo = false
    @State private var showingExportSheet = false

    var body: some View {
        NavigationView {
            List {
                // Vehicles section for display management
                let allVehicles = displayedVehicles
                if !allVehicles.isEmpty {
                    Section {
                        ForEach(displayedVehicles, id: \.id) { bbVehicle in
                            NavigationLink(destination: VehicleInfoView(
                                bbVehicle: bbVehicle,
                            )) {
                                VStack(alignment: .leading) {
                                    Text(bbVehicle.displayName)
                                        .font(.headline)
                                    Text("VIN: \(bbVehicle.vin)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onMove(perform: moveVehicles)
                        .onDelete(perform: hideVehicles)
                    } header: {
                        Text("Vehicles")
                    }
                }

                Section {
                    ForEach(accounts) { account in
                        NavigationLink(destination: AccountInfoView(
                            account: account,
                        )) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(account.username)
                                        .font(.headline)
                                    Text(account.brandEnum.displayName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                        }
                    }
                    .onDelete(perform: deleteAccounts)
                } header: {
                    HStack {
                        Text("Accounts")
                        Spacer()
                        NavigationLink("Add Account") {
                            AddAccountView()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }

                Section {
                    Picker("Refresh Interval", selection: $appSettings.widgetRefreshInterval) {
                        ForEach(WidgetRefreshInterval.allCases, id: \.rawValue) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    Toggle("Widget Notifications", isOn: $appSettings.notificationsEnabled)
                    Toggle(isOn: $appSettings.liveActivitiesEnabled) {
                        HStack(spacing: 6) {
                            Text("Live Activities")
                            Button {
                                showingLiveActivitiesInfo = true
                            } label: {
                                Text("Beta")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Widget Settings")
                }

                Section {
                    Picker("Distance Unit", selection: $appSettings.preferredDistanceUnit) {
                        ForEach(Distance.Units.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }

                    Picker("Temperature Unit", selection: $appSettings.preferredTemperatureUnit) {
                        ForEach(Temperature.Units.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                } header: {
                    Text("Units")
                }

                Section {
                    Toggle("Debug Mode", isOn: $appSettings.debugModeEnabled)

                    if appSettings.debugModeEnabled {
                        #if DEBUG
                            NavigationLink("Map Centering Debug") {
                                MapCenteringDebugView()
                            }
                        #endif

                        NavigationLink("HTTP Logs") {
                            HTTPLogView()
                        }

                        NavigationLink("Sync Diagnostics") {
                            DiagnosticInfoView()
                        }
                    }

                    Button("Clear All Data") {
                        showingClearDataAlert = true
                    }
                    .foregroundColor(.red)

                    if let result = clearDataResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("Error") ? .red : .green)
                    }

                    Button("Export Debug Data") {
                        showingExportSheet = true
                    }
                } header: {
                    Text("Debug Settings")
                }

                // About section with version and GitHub links
                Section {
                    if let version = Bundle.main.releaseVersionNumber, let build = Bundle.main.buildVersionNumber {
                        HStack {
                            Label("Version Number", systemImage: "calendar")
                            Spacer()
                            Text(version)
                        }
                        HStack {
                            Label("Build Number", systemImage: "swift")
                            Spacer()
                            Text(build)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/schmidtwmark/BetterBlue")!) {
                        Label("App Source Code", systemImage: "location.app")
                    }

                    Link(destination: URL(string: "https://github.com/schmidtwmark/BetterBlueKit")!) {
                        Label("Client Source Code", systemImage: "apple.terminal")
                    }
                } header: {
                    Text("About")
                }

                Section {
                    Link(destination: URL(string: "https://apps.apple.com/qa/developer/mark-schmidt/id1502505700")!) {
                        Label("My Other Apps", systemImage: "storefront")
                    }
                } header: {
                    Text("Shameless Self Promotion")
                } footer: {
                    let link = "[Mark Schmidt](https://markschmidt.io)"
                    if let mailLink = try? AttributedString(markdown: "Created by \(link)") {
                        Text(mailLink)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Clear All Data", isPresented: $showingClearDataAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                clearAllData()
            }
        } message: {
            Text(
                "This will permanently delete all accounts, vehicles, debug " +
                    "configurations, and other app data. This action cannot be undone.",
            )
        }
        .sheet(isPresented: $showingLiveActivitiesInfo) {
            LiveActivitiesInfoSheet()
        }
        .sheet(isPresented: $showingExportSheet) {
            DebugExportSheet(accounts: accounts, appSettings: appSettings)
        }
    }

    private func deleteAccounts(offsets: IndexSet) {
        for index in offsets {
            BBAccount.removeAccount(accounts[index], modelContext: modelContext)
        }
    }

    private func getSortedVehiclesForSettings() -> [BBVehicle] {
        displayedVehicles
    }

    private func moveVehicles(from source: IndexSet, to destination: Int) {
        var vehicles = Array(displayedVehicles)
        vehicles.move(fromOffsets: source, toOffset: destination)

        // Update sort orders based on new positions
        for (index, vehicle) in vehicles.enumerated() {
            vehicle.sortOrder = index
        }

        do {
            try modelContext.save()
        } catch {
            BBLogger.error(.app, "SettingsView: Failed to update vehicle order: \(error)")
        }
    }

    private func hideVehicles(offsets: IndexSet) {
        for index in offsets {
            let bbVehicle = displayedVehicles[index]
            bbVehicle.isHidden = true
            do {
                try modelContext.save()
            } catch {
                BBLogger.error(.app, "SettingsView: Failed to hide vehicle: \(error)")
            }
        }
    }

    private func clearAllData() {
        do {
            // Delete all BBAccounts (which should cascade delete their vehicles due to .cascade relationship)
            try modelContext.delete(model: BBAccount.self)

            // Delete any orphaned BBVehicles that might still exist
            try modelContext.delete(model: BBVehicle.self)

            // Delete any orphaned climate presets
            try modelContext.delete(model: ClimatePreset.self)

            // Delete any HTTP logs
            try modelContext.delete(model: BBHTTPLog.self)

            try modelContext.save()

            clearDataResult = "✅ All data cleared successfully"
            BBLogger.info(.app, "SettingsView: Successfully cleared all SwiftData storage")

            // Clear the result message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                clearDataResult = nil
            }
        } catch {
            clearDataResult = "❌ Error: \(error.localizedDescription)"
            BBLogger.error(.app, "SettingsView: Failed to clear data: \(error)")

            // Clear the error message after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                clearDataResult = nil
            }
        }
    }

}

// MARK: - Debug Export Data

private struct DebugExportData {
    let raw: String
    let redacted: String

    @MainActor
    static func generate(accounts: [BBAccount], appSettings: AppSettings) async -> DebugExportData {
        // Create export structure using Codable
        let export = DebugExportContent(
            appInfo: DebugExportContent.AppInfo(
                version: Bundle.main.releaseVersionNumber ?? "unknown",
                build: Bundle.main.buildVersionNumber ?? "unknown",
                exportDate: Date()
            ),
            appSettings: DebugExportContent.AppSettingsExport(
                preferredDistanceUnit: appSettings.preferredDistanceUnit.rawValue,
                preferredTemperatureUnit: appSettings.preferredTemperatureUnit.rawValue,
                notificationsEnabled: appSettings.notificationsEnabled,
                widgetRefreshInterval: appSettings.widgetRefreshInterval.rawValue,
                debugModeEnabled: appSettings.debugModeEnabled,
                liveActivitiesEnabled: appSettings.liveActivitiesEnabled
            ),
            accounts: accounts
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let rawJSON: String
        do {
            let jsonData = try encoder.encode(export)
            rawJSON = String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            rawJSON = "Error generating export: \(error.localizedDescription)"
        }

        let redactedJSON = SensitiveDataRedactor.redact(rawJSON) ?? rawJSON

        return DebugExportData(raw: rawJSON, redacted: redactedJSON)
    }
}

private struct DebugExportContent: Encodable {
    let appInfo: AppInfo
    let appSettings: AppSettingsExport
    let accounts: [BBAccount]

    struct AppInfo: Encodable {
        let version: String
        let build: String
        let exportDate: Date
    }

    struct AppSettingsExport: Encodable {
        let preferredDistanceUnit: String
        let preferredTemperatureUnit: String
        let notificationsEnabled: Bool
        let widgetRefreshInterval: Int
        let debugModeEnabled: Bool
        let liveActivitiesEnabled: Bool
    }
}

// MARK: - Debug Export Sheet

private enum ExportMode: String, CaseIterable {
    case redacted = "Redacted"
    case raw = "Unredacted"
}

private struct DebugExportSheet: View {
    let accounts: [BBAccount]
    let appSettings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @State private var exportData: DebugExportData?
    @State private var showingShareSheet = false
    @State private var exportMode: ExportMode = .redacted

    private var displayedContent: String {
        guard let data = exportData else { return "" }
        return exportMode == .redacted ? data.redacted : data.raw
    }

    var body: some View {
        NavigationView {
            Group {
                if exportData == nil {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating export...")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        Text(displayedContent)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Debug Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                if exportData != nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Export Mode", selection: $exportMode) {
                            ForEach(ExportMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(activityItems: [displayedContent])
            }
            .task {
                exportData = await DebugExportData.generate(
                    accounts: accounts,
                    appSettings: appSettings
                )
            }
        }
    }
}

// MARK: - Live Activities Info Sheet

private struct LiveActivitiesInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Live Activities", systemImage: "bolt.fill")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Beta Feature")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // What it does
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What it does")
                            .font(.headline)
                        Text(
                            "When enabled, BetterBlue will display a Live Activity on your " +
                            "Lock Screen and Dynamic Island while your vehicle is charging. " +
                            "The Live Activity shows real-time charging progress without " +
                            "needing to open the app."
                        )
                        .foregroundColor(.secondary)
                    }

                    // How it works
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How it works")
                            .font(.headline)
                        Text(
                            "To keep the Live Activity updated, BetterBlue registers your " +
                            "device with a lightweight backend service that periodically " +
                            "sends silent push notifications to wake the app and refresh " +
                            "the charging status."
                        )
                        .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Why Beta?").font(.headline)
                        Text(
                            "Live Activities are considered a Beta feature for now. " +
                            "Supporting push notifications in this way requires paying for " +
                            "cloud server time. If this feature ends up being too expensive " +
                            "to maintain, I will likely disable it."
                        )
                        .foregroundColor(.secondary)
                    }

                    // Privacy section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Your Privacy", systemImage: "lock.shield.fill")
                            .font(.headline)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 8) {
                            PrivacyBullet(
                                icon: "checkmark.circle.fill",
                                text: "No vehicle information is sent to the backend"
                            )
                            PrivacyBullet(
                                icon: "checkmark.circle.fill",
                                text: "No account credentials leave your device"
                            )
                            PrivacyBullet(
                                icon: "checkmark.circle.fill",
                                text: "Only your device's push token is stored"
                            )
                            PrivacyBullet(
                                icon: "checkmark.circle.fill",
                                text: "Tokens are automatically deleted after 8 hours"
                            )
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Open source
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open Source")
                            .font(.headline)
                        Text(
                            "The backend service is fully open source. You can review " +
                            "exactly what data is collected and how it's used."
                        )
                        .foregroundColor(.secondary)

                        Button {
                            if let url = URL(string: "https://github.com/schmidtwmark/BetterBlue/tree/main/LiveActivityBackend") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("View Backend Source Code")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("About Live Activities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PrivacyBullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.green)
                .font(.subheadline)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            SettingsView()
                .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self])
        }
    }
    return PreviewWrapper()
}
