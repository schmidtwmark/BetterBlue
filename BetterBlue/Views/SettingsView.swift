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

                        Button("Clear All Data") {
                            showingClearDataAlert = true
                        }
                        .foregroundColor(.red)

                        if let result = clearDataResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result.contains("Error") ? .red : .green)
                        }
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

#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            SettingsView()
                .modelContainer(for: [BBAccount.self, BBVehicle.self, ClimatePreset.self])
        }
    }
    return PreviewWrapper()
}
