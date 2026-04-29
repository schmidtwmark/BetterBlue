//
//  SettingsView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 7/14/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

/// Sections shown in the macCatalyst settings sidebar. Order here drives
/// the row order in the sidebar via `CaseIterable`.
enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case vehicles
    case general
    case widgets
    case menuBar
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicles: return "Vehicles"
        case .general: return "General"
        case .widgets: return "Widgets"
        case .menuBar: return "Menu Bar"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .vehicles: return "car.fill"
        case .general: return "gearshape"
        case .widgets: return "rectangle.3.group"
        case .menuBar: return "menubar.rectangle"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
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
    /// Selected section in the macCatalyst sidebar. Defaults to `.vehicles`
    /// (the first row) so the detail pane is populated on first open.
    @State private var selectedMacSection: SettingsSection? = .vehicles

    var body: some View {
        #if os(macOS)
            macSidebarBody
        #else
            iOSListBody
        #endif
    }

    // MARK: - iOS (sheet-style list) body — unchanged from pre-Mac work.

    @ViewBuilder
    private var iOSListBody: some View {
        NavigationView {
            List {
                vehiclesSection
                accountsSection
                widgetSettingsSection
                #if os(macOS)
                menuBarSection
                #endif
                unitsSection
                debugSection
                helpSection
                aboutSection
                creditsSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .settingsSheetsAndAlerts(
            showingClearDataAlert: $showingClearDataAlert,
            showingLiveActivitiesInfo: $showingLiveActivitiesInfo,
            showingExportSheet: $showingExportSheet,
            clearAction: clearAllData,
            accounts: accounts,
            appSettings: appSettings,
            modelContext: modelContext
        )
    }

    // MARK: - macOS (System Settings-style sidebar + detail) body.

    /// Mirrors macOS's System Settings app: a fixed-width sidebar on the
    /// left with one row per section, and the selected section's content
    /// rendered in the detail pane on the right.
    @ViewBuilder
    private var macSidebarBody: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedMacSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            NavigationStack {
                macDetail(for: selectedMacSection ?? .vehicles)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        .settingsSheetsAndAlerts(
            showingClearDataAlert: $showingClearDataAlert,
            showingLiveActivitiesInfo: $showingLiveActivitiesInfo,
            showingExportSheet: $showingExportSheet,
            clearAction: clearAllData,
            accounts: accounts,
            appSettings: appSettings,
            modelContext: modelContext
        )
    }

    @ViewBuilder
    private func macDetail(for section: SettingsSection) -> some View {
        switch section {
        case .vehicles:
            List {
                vehiclesSection
                accountsSection
            }
            .navigationTitle("Vehicles")
        case .general:
            Form {
                unitsSection
            }
            .navigationTitle("General")
        case .widgets:
            Form {
                widgetSettingsSection
            }
            .navigationTitle("Widgets")
        case .menuBar:
            Form {
                menuBarSection
            }
            .navigationTitle("Menu Bar")
        case .advanced:
            List {
                debugSection
                helpSection
            }
            .navigationTitle("Advanced")
        case .about:
            List {
                aboutSection
                creditsSection
            }
            .navigationTitle("About")
        }
    }

    // MARK: - Section builders (shared across both bodies)

    @ViewBuilder
    private var vehiclesSection: some View {
        if !displayedVehicles.isEmpty {
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
    }

    @ViewBuilder
    private var accountsSection: some View {
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
    }

    @ViewBuilder
    private var widgetSettingsSection: some View {
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
    }

    @ViewBuilder
    private var menuBarSection: some View {
        Section {
            Toggle("Menu Bar App", isOn: $appSettings.menuBarEnabled)
            if appSettings.menuBarEnabled {
                Toggle("Show Dock Icon", isOn: $appSettings.showDockIcon)
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text(
                "Show a menu bar icon for each vehicle with quick controls. "
                + "Menu bar refreshes run on the same interval as the widget refresh above, "
                + "and appear in HTTP Logs tagged as 'Menu Bar'."
            )
        }
    }

    @ViewBuilder
    private var unitsSection: some View {
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
    }

    @ViewBuilder
    private var debugSection: some View {
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
    }

    @ViewBuilder
    private var helpSection: some View {
        Section {
            NavigationLink(destination: TroubleshootingView()) {
                Label("Troubleshooting", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Help")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
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
    }

    @ViewBuilder
    private var creditsSection: some View {
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

// MARK: - Shared sheets / alert chain

private extension View {
    func settingsSheetsAndAlerts(
        showingClearDataAlert: Binding<Bool>,
        showingLiveActivitiesInfo: Binding<Bool>,
        showingExportSheet: Binding<Bool>,
        clearAction: @escaping () -> Void,
        accounts: [BBAccount],
        appSettings: AppSettings,
        modelContext: ModelContext
    ) -> some View {
        self
            .alert("Clear All Data", isPresented: showingClearDataAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    clearAction()
                }
            } message: {
                Text(
                    "This will permanently delete all accounts, vehicles, debug " +
                        "configurations, and other app data. This action cannot be undone."
                )
            }
            .sheet(isPresented: showingLiveActivitiesInfo) {
                LiveActivitiesInfoSheet()
            }
            .sheet(isPresented: showingExportSheet) {
                DebugExportSheet(
                    accounts: accounts,
                    appSettings: appSettings,
                    modelContext: modelContext
                )
            }
    }
}

// `DebugExportData` and its supporting Codable types live in
// `BetterBlue/Utility/DebugExport.swift` so the error-detail share
// button produces the same payload as Settings → Export Debug Data.

// MARK: - Debug Export Sheet

private enum ExportMode: String, CaseIterable {
    case redacted = "Redacted"
    case raw = "Unredacted"
}

private struct DebugExportSheet: View {
    let accounts: [BBAccount]
    let appSettings: AppSettings
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss
    @State private var exportData: DebugExportData?
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
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
                    ToolbarItem(placement: .automatic) {
                        // Cross-platform: ShareLink works on iOS / iPadOS
                        // / macOS without us juggling UIActivityViewController
                        // vs NSSharingService directly.
                        ShareLink(item: displayedContent) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .task {
                exportData = await DebugExportData.generate(
                    accounts: accounts,
                    appSettings: appSettings,
                    modelContext: modelContext
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
                                #if os(iOS)
                                    UIApplication.shared.open(url)
                                #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                #endif
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
