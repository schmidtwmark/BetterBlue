//
//  ErrorDetailsView.swift
//  BetterBlue
//
//  Reusable error card used throughout the app. Shows:
//    1. What action failed (caller-supplied).
//    2. What type of error it was (derived from APIError.errorType when
//       available, or the raw error's localizedDescription otherwise).
//    3. Technical details — APIError internals plus the most recent
//       HTTP log for the affected account — hidden behind a disclosure
//       so normal users aren't faced with a wall of JSON.
//

import BetterBlueKit
import SwiftData
import SwiftUI

/// Bundle of error context a view can hand to `ErrorDetailsView`.
///
/// Construct one of these at the catch site — that's where the verb
/// ("what I was trying to do") is known. Passing the `Error` through
/// lets the detail view fish out an `APIError` if that's what it was.
struct ActionError: Equatable {
    /// The thing the user was trying to do, phrased as a verb noun
    /// phrase: `"Send verification code"`, `"Lock vehicle"`, etc. Used
    /// verbatim in the headline, capitalised by the caller.
    let action: String
    /// The raw error caught from the call. Kept as `Error` (not
    /// `APIError`) so non-API errors flow through with usable text too.
    let error: Error
    /// Optional account scope. When set, `ErrorDetailsView` surfaces the
    /// latest `BBHTTPLog` for that account inside the technical-details
    /// disclosure — otherwise the raw-response section is skipped.
    let accountId: UUID?

    init(action: String, error: Error, accountId: UUID? = nil) {
        self.action = action
        self.error = error
        self.accountId = accountId
    }

    /// Strongly-typed API error if that's what the caller caught.
    var apiError: APIError? { error as? APIError }

    /// Headline text. `\(action) failed.`
    var headline: String { "\(action) failed." }

    /// One-line summary combining the error-type label and the
    /// underlying message, falling back to `localizedDescription`.
    var summary: String {
        if let apiError {
            return "\(apiError.errorType.displayLabel): \(apiError.message)"
        }
        return error.localizedDescription
    }

    static func == (lhs: ActionError, rhs: ActionError) -> Bool {
        lhs.action == rhs.action
            && lhs.accountId == rhs.accountId
            && (lhs.error as NSError) == (rhs.error as NSError)
    }
}

/// Renders an `ActionError` as a compact, tappable error card: red
/// headline and summary line. Tapping anywhere on the card opens a
/// half-height sheet containing the summary and the full raw error
/// details, plus a Share button in the toolbar for copying the whole
/// thing into a bug report.
struct ErrorDetailsView: View {
    let error: ActionError
    @State private var showDetails = false

    var body: some View {
        Button {
            showDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(error.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(error.summary)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetails) {
            ErrorDetailsSheet(error: error) { showDetails = false }
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Sheet content

/// Half-height sheet: prominent summary at the top, raw error details
/// directly below. Toolbar share button shares the same JSON payload
/// produced by Settings → Export Debug Data (redacted), so when a user
/// sends a report I get exactly the same shape of info.
///
/// Not private: `VehicleCardView` and `VehicleControlButton` present
/// this directly so the banner → details flow is a single tap.
struct ErrorDetailsSheet: View {
    let error: ActionError
    let onDismiss: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [BBAccount]
    @State private var shareText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Emphasised human-readable section
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error.headline)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(error.summary)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Raw details directly below — no disclosure.
                    ErrorTechnicalDetails(error: error, latestLog: latestLog)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Error Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Share on the leading side per request.
                ToolbarItem(placement: .automatic) {
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(shareText.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Done", action: onDismiss)
                }
            }
            .task {
                // Build the full debug export once when the sheet opens.
                // Uses the same code path as Settings → Export Debug Data
                // (redacted variant). We pass `currentError:` so the
                // payload also carries the specific `ActionError` the
                // user was looking at — one unified share content.
                let data = await DebugExportData.generate(
                    accounts: accounts,
                    appSettings: AppSettings.shared,
                    modelContext: modelContext,
                    currentError: error
                )
                shareText = data.redacted
            }
        }
    }

    /// Latest HTTP log for this error's account, used to populate the
    /// on-screen raw-details block. The share text uses the full
    /// `DebugExportData` payload rather than this single log.
    private var latestLog: HTTPLog? {
        guard let accountId = error.accountId else { return nil }
        let predicate = #Predicate<BBHTTPLog> { $0.log.accountId == accountId }
        var descriptor = FetchDescriptor<BBHTTPLog>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.log.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.log
    }
}

// MARK: - JSON pretty-print helper
//
// Shared between `ErrorTechnicalDetails` (on-screen rendering) and
// `ErrorDetailsSheet.shareText` so the clipboard version matches what
// the user sees in the sheet.
enum TechnicalDetailsFormatting {
    static func prettyPrintJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return string
    }
}

// MARK: - Raw details block (shown below the summary in the sheet)

private struct ErrorTechnicalDetails: View {
    let error: ActionError
    let latestLog: HTTPLog?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let apiError = error.apiError {
                DetailRow(key: "Type", value: apiError.errorType.displayLabel)
                if let code = apiError.code {
                    DetailRow(key: "Code", value: String(code))
                }
                if let apiName = apiError.apiName, !apiName.isEmpty {
                    DetailRow(key: "API", value: apiName)
                }
                DetailRow(key: "Message", value: apiError.message)
            } else {
                DetailRow(key: "Description", value: error.error.localizedDescription)
            }

            if let log = latestLog {
                Divider()
                    .padding(.vertical, 2)
                Text("Latest request")
                    .font(.caption.weight(.semibold))
                DetailRow(key: "URL", value: log.url)
                DetailRow(key: "Status", value: log.statusText)
                if let body = log.responseBody?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    Text("Response body")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 4)
                    // Monospaced scrollable block so a large JSON dump
                    // doesn't blow the layout. `textSelection(.enabled)`
                    // lets users copy/paste into an issue.
                    ScrollView {
                        Text(TechnicalDetailsFormatting.prettyPrintJSON(body))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

private struct DetailRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#Preview("API error") {
    Form {
        Section {
            ErrorDetailsView(
                error: ActionError(
                    action: "Send verification code",
                    error: APIError(
                        message: "Invalid request payload",
                        code: 9001,
                        apiName: "KiaUSA",
                        errorType: .kiaInvalidRequest
                    )
                )
            )
        }
    }
}

#Preview("Plain error") {
    List {
        Section {
            ErrorDetailsView(
                error: ActionError(
                    action: "Refresh vehicle status",
                    error: NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorTimedOut,
                        userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
                    )
                )
            )
        }
    }
}
