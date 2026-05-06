//
//  WatchErrorSheet.swift
//  BetterBlueWatch Watch App
//
//  Compact error presentation for the Watch. Mirrors the iOS
//  `ErrorDetailsSheet` headline/summary treatment but stays within the
//  small footprint and avoids the iOS-specific debug-export plumbing
//  (HTTP log fetching, ShareLink, etc.) which doesn't translate well
//  to the watch.
//

import BetterBlueKit
import SwiftUI

private extension String {
    /// Lowercases just the first character so "Start Climate" becomes
    /// "start Climate" — keeps proper nouns / acronyms intact while
    /// fitting cleanly after a "Failed to …" prefix.
    var lowercasedFirstLetter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// Minimal error context the watch needs to render the sheet. Mirrors
/// the shape of the iOS `ActionError` so call sites read the same.
struct WatchActionError: Equatable, Identifiable {
    let id = UUID()
    /// Imperative verb phrase describing what the user was trying to do
    /// ("Lock", "Start Climate", etc.). Combined with a "Failed to …"
    /// prefix in `headline` so the result is grammatical regardless of
    /// what the caller passes in.
    let action: String
    /// The raw error caught from the call.
    let error: Error

    var headline: String { "Failed to \(action.lowercasedFirstLetter)." }

    var summary: String {
        if let apiError = error as? APIError {
            return "\(apiError.errorType.displayLabel): \(apiError.message)"
        }
        return error.localizedDescription
    }

    static func == (lhs: WatchActionError, rhs: WatchActionError) -> Bool {
        lhs.id == rhs.id
            && lhs.action == rhs.action
            && (lhs.error as NSError) == (rhs.error as NSError)
    }
}

/// Sheet shown after a failed Watch action. Headline (red), one-line
/// summary, and any extra technical detail we have. Single Dismiss
/// button — full HTTP log inspection is left to the iPhone app.
struct WatchErrorSheet: View {
    let error: WatchActionError
    let onDismiss: () -> Void

    private var apiError: APIError? { error.error as? APIError }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(error.headline)
                    .font(.headline)
                    .foregroundStyle(.red)

                Text(error.summary)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let apiError {
                    VStack(alignment: .leading, spacing: 4) {
                        if let code = apiError.code {
                            detailRow("Code", value: String(code))
                        }
                        if let apiName = apiError.apiName, !apiName.isEmpty {
                            detailRow("API", value: apiName)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func detailRow(_ key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(key):")
                .fontWeight(.semibold)
            Text(value)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}
