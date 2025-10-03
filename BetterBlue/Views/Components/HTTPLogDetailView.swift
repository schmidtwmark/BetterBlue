//
//  HTTPLogDetailView.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import Highlight
import SwiftUI

struct HTTPLogDetailView: View {
    let log: HTTPLog
    var transition: Namespace.ID?
    @Namespace private var fallbackTransition
    @State private var copiedMessage: String?

    var body: some View {
        TabView {
            // Request Tab
            HTTPLogContentView(
                title: "Request",
                details: [
                    "Method": log.method,
                    "URL": log.url,
                    "Timestamp": DateFormatter.httpLogFormatter.string(from: log.timestamp),
                    "Duration": String(format: "%.2f seconds", log.duration)
                ],
                headers: log.requestHeaders,
                formattedBody: log.formattedRequestBody,
                copiedMessage: $copiedMessage
            )
            .tabItem {
                Image(systemName: "arrow.up.circle")
                Text("Request")
            }

            // Response Tab
            HTTPLogContentView(
                title: "Response",
                details: {
                    var responseDetails: [String: String] = [
                        "Status Code": log.responseStatus?.description ?? "Unknown"
                    ]
                    if let error = log.error {
                        responseDetails["Error"] = error
                    }
                    return responseDetails
                }(),
                headers: log.responseHeaders,
                formattedBody: log.formattedResponseBody,
                copiedMessage: $copiedMessage
            )
            .tabItem {
                Image(systemName: "arrow.down.circle")
                Text("Response")
            }

            // Stack Trace Tab (only show if stack trace exists)
            if log.stackTrace != nil {
                HTTPLogStackTraceView(
                    log: log,
                    copiedMessage: $copiedMessage
                )
                .tabItem {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Stack Trace")
                }
            }
        }
        .navigationTitle("HTTP Log Details")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let message = copiedMessage {
                Text(message)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
            }
        }
    }
}

extension HTTPLog {
    var formattedRequestBody: NSAttributedString? {
        guard let requestBody else { return nil }
        return formatJSON(requestBody)
    }

    var formattedResponseBody: NSAttributedString? {
        guard let responseBody else { return nil }
        return formatJSON(responseBody)
    }

    func formatJSON(_ jsonString: String) -> NSAttributedString {
        guard let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let formattedData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
              let formattedString = String(data: formattedData, encoding: .utf8)
        else { return NSAttributedString(string: jsonString) }

        return JsonSyntaxHighlightProvider.shared.highlight(formattedString, as: .json)
    }
}

// Unified HTTP Log Content View
struct HTTPLogContentView: View {
    let title: String
    let details: [String: String]
    let headers: [String: String]
    let formattedBody: NSAttributedString?
    @Binding var copiedMessage: String?
    @State private var showingShareSheet = false

    var body: some View {
        List {
            Section("\(title) Details") {
                ForEach(Array(details.sorted(by: { $0.key < $1.key })), id: \.key) { element in
                    TapToCopyRow(label: element.key, value: element.value, copiedMessage: $copiedMessage)
                }
            }

            if !headers.isEmpty {
                Section("\(title) Headers") {
                    ForEach(Array(headers.sorted(by: { $0.key < $1.key })), id: \.key) { element in
                        TapToCopyRow(label: element.key, value: element.value, copiedMessage: $copiedMessage)
                    }
                }
            }

            if let body = formattedBody {
                Section {
                    JSONBodyView(
                        content: body,
                        showingShareSheet: $showingShareSheet
                    )
                } header: {
                    HStack {
                        Text("\(title) Body")
                        Spacer()
                        Button("Share", systemImage: "square.and.arrow.up") {
                            showingShareSheet = true
                        }
                        .labelStyle(.iconOnly)
                        .foregroundColor(.blue)
                    }
                }
            }
        }
    }
}

// Stack Trace Tab Content
struct HTTPLogStackTraceView: View {
    let log: HTTPLog
    @Binding var copiedMessage: String?
    @State var showingRawStackTrace: Bool = false
    @State var showingShareSheet: Bool = false

    var rawStackTraceButtonText: String {
        showingRawStackTrace ? "Show Processed" : "Show Raw"
    }

    var body: some View {
        List {
            Section {
                StackTraceView(
                    log: log,
                    showingRawStackTrace: $showingRawStackTrace,
                    showingShareSheet: $showingShareSheet
                )
            } header: {
                HStack {
                    Text("Stack Trace")
                    Spacer()
                    Menu {
                        Button(rawStackTraceButtonText, systemImage: "eye") {
                            showingRawStackTrace.toggle()
                        }
                        Button("Share", systemImage: "square.and.arrow.up") {
                            showingShareSheet = true
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .foregroundColor(.blue)
                }
            }
        }
    }
}

// Supporting views
struct InfoSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            content
        }
        .padding(.vertical, 4)
    }
}

struct TapToCopyRow: View {
    let label: String
    let value: String
    @Binding var copiedMessage: String?

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)

            Spacer()

            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            copyToClipboard()
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = value

        withAnimation(.easeInOut(duration: 0.3)) {
            copiedMessage = "\(label) copied to clipboard"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                copiedMessage = nil
            }
        }
    }
}

// Date formatter extension
private extension DateFormatter {
    static let httpLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

#Preview {
    struct PreviewWrapper: View {
        @State private var copiedMessage: String?

        var body: some View {
            let sampleLog = HTTPLog(
                timestamp: Date(),
                accountId: UUID(),
                requestType: .sendCommand,
                method: "POST",
                url: "https://prd.eu-ccapi.hyundai.com/api/v2/spa/vehicles/KMHL14JA5KA123456/control/engine",
                requestHeaders: [
                    "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "User-Agent": "BetterBlue/1.0"
                ],
                requestBody: """
                {
                    "action": "start",
                    "hvacSettings": {
                        "temperature": 22,
                        "defrost": false,
                        "airControl": true,
                        "steeringWheelHeat": false
                    },
                    "pin": "1234"
                }
                """,
                responseStatus: 400,
                responseHeaders: [
                    "Content-Type": "application/json",
                    "Date": "Wed, 08 Sep 2025 20:30:00 GMT",
                    "Server": "nginx/1.18.0"
                ],
                responseBody: """
                {
                    "error": {
                        "code": "INVALID_PIN",
                        "message": "The provided PIN is invalid or has expired",
                        "details": {
                            "attemptCount": 2,
                            "maxAttempts": 3,
                            "lockoutTime": null
                        }
                    },
                    "requestId": "req_12345678-90ab-cdef-1234-567890abcdef",
                    "timestamp": "2025-09-08T20:30:00Z"
                }
                """,
                error: "Invalid PIN provided",
                duration: 2.45,
                stackTrace: """
                HTTPLogDetailView.swift:156
                VehicleCommandHandler.swift:89
                MainView.swift:234
                BetterBlueApp.swift:67
                """
            )

            return NavigationView {
                HTTPLogDetailView(log: sampleLog)
            }
        }
    }

    return PreviewWrapper()
}
