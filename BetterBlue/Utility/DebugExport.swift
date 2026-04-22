//
//  DebugExport.swift
//  BetterBlue
//
//  Shared builder for the "Export Debug Data" JSON payload. Used both by
//  Settings → Export Debug Data (raw / redacted toggle, attaches as
//  text file) and by `ErrorDetailsSheet`'s share button (redacted, plain
//  text). Keeping the generator in one place means the two outputs are
//  always identical — when a user shares an error with me from an error
//  card, I get the same shape of info as a full debug export.
//

import BetterBlueKit
import Foundation
import SwiftData

/// Both a raw and redacted JSON string for the current app state:
/// accounts (with their vehicles + relevant HTTP logs), app settings,
/// and build metadata. When generated from an error context, also
/// includes the full `ActionError` (headline, summary, underlying
/// APIError fields) so support reports carry the specific failure plus
/// the wider app state in a single payload.
struct DebugExportData {
    let raw: String
    let redacted: String

    @MainActor
    static func generate(
        accounts: [BBAccount],
        appSettings: AppSettings,
        modelContext: ModelContext,
        currentError: ActionError? = nil
    ) async -> DebugExportData {
        // Fetch HTTP logs for each account
        var accountExports: [AccountExport] = []
        for account in accounts {
            let httpLogs = fetchHTTPLogsForAccount(
                accountId: account.id,
                vehicles: account.safeVehicles,
                modelContext: modelContext
            )
            accountExports.append(AccountExport(account: account, httpLogs: httpLogs))
        }

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
            accounts: accountExports,
            currentError: currentError.map(ErrorExport.init(from:))
        )

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

    /// Picks out the "most interesting" HTTP logs for one account:
    /// latest login, latest vehicles fetch, and the latest status fetch
    /// per vehicle. Matches `log.vin` first with fallbacks to headers
    /// and body for logs written before `HTTPLog.vin` existed.
    @MainActor
    static func fetchHTTPLogsForAccount(
        accountId: UUID,
        vehicles: [BBVehicle],
        modelContext: ModelContext
    ) -> AccountHTTPLogs {
        let predicate = #Predicate<BBHTTPLog> { $0.log.accountId == accountId }
        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.log.timestamp, order: .reverse)]
        )

        let allLogs: [BBHTTPLog]
        do {
            allLogs = try modelContext.fetch(descriptor)
        } catch {
            return AccountHTTPLogs(login: nil, getVehicles: nil, vehicleStatuses: [])
        }

        let loginLog = allLogs.first { $0.log.requestType == .login }?.log
        let getVehiclesLog = allLogs.first { $0.log.requestType == .fetchVehicles }?.log

        var vehicleStatuses: [HTTPLog] = []
        for vehicle in vehicles {
            if let statusLog = allLogs.first(where: {
                guard $0.log.requestType == .fetchVehicleStatus else { return false }
                if $0.log.vin == vehicle.vin { return true }
                // Backwards-compat for logs written before HTTPLog.vin existed.
                let headers = $0.log.requestHeaders
                if headers["vin"] == vehicle.vin || headers["APPCLOUD-VIN"] == vehicle.vin {
                    return true
                }
                if let body = $0.log.requestBody, body.contains(vehicle.vin) {
                    return true
                }
                return $0.log.url.contains(vehicle.vin)
            })?.log {
                vehicleStatuses.append(statusLog)
            }
        }

        return AccountHTTPLogs(login: loginLog, getVehicles: getVehiclesLog, vehicleStatuses: vehicleStatuses)
    }
}

// MARK: - Encodable wrappers

struct AccountHTTPLogs: Encodable {
    let login: HTTPLog?
    let getVehicles: HTTPLog?
    let vehicleStatuses: [HTTPLog]

    enum CodingKeys: String, CodingKey {
        case login, getVehicles, vehicleStatuses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(login.map { HTTPLogExport(log: $0) }, forKey: .login)
        try container.encodeIfPresent(getVehicles.map { HTTPLogExport(log: $0) }, forKey: .getVehicles)
        try container.encode(vehicleStatuses.map { HTTPLogExport(log: $0) }, forKey: .vehicleStatuses)
    }
}

struct AccountExport: Encodable {
    let account: BBAccount
    let httpLogs: AccountHTTPLogs

    enum CodingKeys: String, CodingKey {
        case id, username, brand, region, vehicles, httpLogs = "http_logs"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account.id, forKey: .id)
        try container.encode(account.username, forKey: .username)
        try container.encode(account.brand, forKey: .brand)
        try container.encode(account.region, forKey: .region)
        try container.encode(account.safeVehicles, forKey: .vehicles)
        try container.encode(httpLogs, forKey: .httpLogs)
    }
}

struct DebugExportContent: Encodable {
    let appInfo: AppInfo
    let appSettings: AppSettingsExport
    let accounts: [AccountExport]
    /// Optional — only set when the export was generated in response to
    /// an in-app error (via `ErrorDetailsSheet`'s share button). Absent
    /// from Settings → Export Debug Data payloads.
    let currentError: ErrorExport?

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

/// Serialisable mirror of `ActionError` so the debug payload carries the
/// specific failure that the user was looking at when they hit Share.
struct ErrorExport: Encodable {
    let action: String
    let headline: String
    let summary: String
    let accountId: UUID?
    let apiError: APIErrorExport?
    let underlyingDescription: String?

    struct APIErrorExport: Encodable {
        let type: String
        let code: Int?
        let apiName: String?
        let message: String
        let userInfo: [String: String]?
    }

    init(from error: ActionError) {
        self.action = error.action
        self.headline = error.headline
        self.summary = error.summary
        self.accountId = error.accountId

        if let apiError = error.apiError {
            self.apiError = APIErrorExport(
                type: apiError.errorType.rawValue,
                code: apiError.code,
                apiName: apiError.apiName,
                message: apiError.message,
                userInfo: apiError.userInfo
            )
            self.underlyingDescription = nil
        } else {
            self.apiError = nil
            self.underlyingDescription = error.error.localizedDescription
        }
    }
}
