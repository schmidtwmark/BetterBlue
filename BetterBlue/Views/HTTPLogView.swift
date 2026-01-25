//
//  HTTPLogView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/4/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct HTTPLogView: View {
    let accountId: UUID?
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\BBHTTPLog.log.timestamp, order: .reverse)]) private var allLogs: [BBHTTPLog]
    @Query private var allAccounts: [BBAccount]
    @State private var selectedRequestTypes: Set<HTTPRequestType> = Set(HTTPRequestType.allCases)
    @State private var selectedDeviceTypes: Set<DeviceType> = Set(DeviceType.allCases)
    @State private var selectedAccountIds: Set<UUID> = []
    @State private var showingFilterSheet = false
    @Namespace private var fallbackTransition

    init(accountId: UUID? = nil, transition: Namespace.ID? = nil) {
        self.accountId = accountId
        self.transition = transition
    }

    var filteredLogs: [BBHTTPLog] {
        allLogs.filter { bbLog in
            let requestTypeMatch = selectedRequestTypes.contains(bbLog.log.requestType)
            let deviceTypeMatch = selectedDeviceTypes.contains(bbLog.deviceType)
            let accountMatch = selectedAccountIds.isEmpty || selectedAccountIds.contains(bbLog.log.accountId)

            return requestTypeMatch && deviceTypeMatch && accountMatch
        }
    }

    var body: some View {
        List {
            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "No HTTP Logs",
                    systemImage: "network.slash",
                    description: Text(accountId != nil ?
                        "HTTP requests will appear here when made by this account." :
                        "HTTP requests will appear here when made by any account."),
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredLogs, id: \.log.id) { bbLog in
                    NavigationLink(
                        destination: HTTPLogDetailView(log: bbLog.log, transition: transition ?? fallbackTransition),
                    ) {
                        HTTPLogRowView(bbLog: bbLog)
                    }
                }
            }
        }
        .navigationTitle("HTTP Logs")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu("Actions") {
                    Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                        showingFilterSheet = true
                    }

                    Divider()

                    Button("Clear All", systemImage: "trash", role: .destructive) {
                        clearAllLogs()
                    }
                }
            }
        }
        .sheet(isPresented: $showingFilterSheet) {
            HTTPLogFilterSheet(
                selectedRequestTypes: $selectedRequestTypes,
                selectedDeviceTypes: $selectedDeviceTypes,
                selectedAccountIds: $selectedAccountIds,
                allAccounts: allAccounts
            )
        }
        .onAppear {
            // If opened for a specific account, pre-filter to that account
            if let accountId = accountId, selectedAccountIds.isEmpty {
                selectedAccountIds = [accountId]
            }
        }
    }

    private func clearAllLogs() {
        for bbLog in allLogs {
            modelContext.delete(bbLog)
        }
        try? modelContext.save()
    }
}

struct HTTPLogRowView: View {
    let bbLog: BBHTTPLog

    var log: HTTPLog {
        bbLog.log
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Request Type Badge
                Text(log.requestType.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.primary)
                    .cornerRadius(4)

                // Method Badge
                Text(log.method)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.primary)
                    .cornerRadius(4)

                Spacer()

                // Status Code Badge
                Text(log.responseStatus?.description ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)

                // Timestamp
                Text(DateFormatter.timeOnlyFormatter.string(from: log.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // URL
            HStack {
                Text(log.url)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Duration and Error
            HStack {
                // Duration
                Text(String(format: "%.2fs", log.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
                // Device Type Badge
                Text(bbLog.deviceType.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(4)

                // Error indicator
                if log.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        guard let status = log.responseStatus else { return .secondary }
        switch status {
        case 200 ... 299: return .green
        case 300 ... 399: return .orange
        case 400 ... 499: return .red
        case 500 ... 599: return .red
        default: return .secondary
        }
    }
}

private extension DateFormatter {
    static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            let testAccountId = UUID()

            // Create an in-memory model container for preview
            let modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container: ModelContainer
            do {
                container = try ModelContainer(
                    for: BBAccount.self, BBVehicle.self, BBHTTPLog.self,
                    configurations: modelConfiguration
                )
            } catch {
                fatalError("Failed to create model container: \(error)")
            }

            // Add sample HTTP logs
            let context = ModelContext(container)

            // Create sample logs with different types and statuses
            let sampleLogs = [
                HTTPLog(
                    timestamp: Date().addingTimeInterval(-300),
                    accountId: testAccountId,
                    requestType: .login,
                    method: "POST",
                    url: "https://prd.eu-ccapi.hyundai.com/api/v1/user/oauth2/authorize",
                    requestHeaders: ["Content-Type": "application/json"],
                    requestBody: nil,
                    responseStatus: 200,
                    responseHeaders: ["Content-Type": "application/json"],
                    responseBody: "{\"access_token\":\"...\"}",
                    error: nil,
                    duration: 1.23,
                    stackTrace: nil
                ),
                HTTPLog(
                    timestamp: Date().addingTimeInterval(-120),
                    accountId: testAccountId,
                    requestType: .fetchVehicles,
                    method: "GET",
                    url: "https://prd.eu-ccapi.hyundai.com/api/v2/spa/vehicles",
                    requestHeaders: ["Authorization": "Bearer ..."],
                    requestBody: nil,
                    responseStatus: 200,
                    responseHeaders: ["Content-Type": "application/json"],
                    responseBody: "{\"vehicles\":[{\"vin\":\"...\"}]}",
                    error: nil,
                    duration: 0.89,
                    stackTrace: nil
                ),
                HTTPLog(
                    timestamp: Date().addingTimeInterval(-60),
                    accountId: testAccountId,
                    requestType: .fetchVehicleStatus,
                    method: "GET",
                    url: "https://prd.eu-ccapi.hyundai.com/api/v2/spa/vehicles/KMHL14JA5KA123456/status/latest",
                    requestHeaders: ["Authorization": "Bearer ..."],
                    requestBody: nil,
                    responseStatus: 200,
                    responseHeaders: ["Content-Type": "application/json"],
                    responseBody: "{\"vehicleStatus\":{\"battery\":{\"level\":85}}}",
                    error: nil,
                    duration: 2.15,
                    stackTrace: nil
                ),
                HTTPLog(
                    timestamp: Date().addingTimeInterval(-30),
                    accountId: testAccountId,
                    requestType: .sendCommand,
                    method: "POST",
                    url: "https://prd.eu-ccapi.hyundai.com/api/v2/spa/vehicles/KMHL14JA5KA123456/control/engine",
                    requestHeaders: ["Authorization": "Bearer ...", "Content-Type": "application/json"],
                    requestBody: "{\"action\":\"start\",\"hvacSettings\":{\"temperature\":20}}",
                    responseStatus: 404,
                    responseHeaders: ["Content-Type": "application/json"],
                    responseBody: "{\"error\":\"Vehicle not found\"}",
                    error: "Vehicle not found",
                    duration: 5.67,
                    stackTrace: "HTTPLogView.swift:42\nMainView.swift:156"
                )
            ]

            // Insert sample logs into the context
            for (index, log) in sampleLogs.enumerated() {
                let deviceType: DeviceType = [.iPhone, .iPad, .mac, .widget, .watch][index % 5]
                let bbLog = BBHTTPLog(log: log, deviceType: deviceType)
                context.insert(bbLog)
            }

            do {
                try context.save()
            } catch {
                BBLogger.error(.app, "Failed to save preview context: \(error)")
            }

            return NavigationView {
                HTTPLogView(accountId: testAccountId)
            }
            .modelContainer(container)
        }
    }
    return PreviewWrapper()
}
