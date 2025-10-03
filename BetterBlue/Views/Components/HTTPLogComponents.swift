//
//  HTTPLogComponents.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/25/25.
//

import BetterBlueKit
import SwiftUI

struct JSONBodyView: View {
    let content: NSAttributedString
    @Binding var showingShareSheet: Bool
    @Namespace private var transition

    var body: some View {
        Text(AttributedString(content))
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(activityItems: [content])
                    .navigationTransition(
                        .zoom(sourceID: "json-share)", in: transition),
                    )
            }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

struct HTTPLogFilterSheet: View {
    @Binding var selectedRequestTypes: Set<HTTPRequestType>
    @Binding var selectedDeviceTypes: Set<DeviceType>
    @Binding var selectedAccountIds: Set<UUID>
    let allAccounts: [BBAccount]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(HTTPRequestType.allCases, id: \.self) { requestType in
                        Button {
                            if selectedRequestTypes.contains(requestType) {
                                selectedRequestTypes.remove(requestType)
                            } else {
                                selectedRequestTypes.insert(requestType)
                            }
                        } label: {
                            HStack {
                                Image(
                                    systemName: selectedRequestTypes.contains(requestType) ?
                                        "checkmark.square.fill" : "square",
                                )
                                .foregroundColor(selectedRequestTypes.contains(requestType) ? .accentColor : .secondary)
                                Text(requestType.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } header: {
                    HStack {
                        Text("Request Types")
                        Spacer()
                        Button("All") {
                            selectedRequestTypes = Set(HTTPRequestType.allCases)
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        Button("None") {
                            selectedRequestTypes = []
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }

                Section {
                    ForEach(DeviceType.allCases, id: \.self) { deviceType in
                        Button {
                            if selectedDeviceTypes.contains(deviceType) {
                                selectedDeviceTypes.remove(deviceType)
                            } else {
                                selectedDeviceTypes.insert(deviceType)
                            }
                        } label: {
                            HStack {
                                Image(
                                    systemName: selectedDeviceTypes.contains(deviceType) ?
                                        "checkmark.square.fill" : "square",
                                )
                                .foregroundColor(selectedDeviceTypes.contains(deviceType) ? .accentColor : .secondary)
                                Text(deviceType.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } header: {
                    HStack {
                        Text("Device Types")
                        Spacer()
                        Button("All") {
                            selectedDeviceTypes = Set(DeviceType.allCases)
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        Button("None") {
                            selectedDeviceTypes = []
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }

                if !allAccounts.isEmpty {
                    Section {
                        ForEach(allAccounts) { account in
                            Button {
                                if selectedAccountIds.contains(account.id) {
                                    selectedAccountIds.remove(account.id)
                                } else {
                                    selectedAccountIds.insert(account.id)
                                }
                            } label: {
                                HStack {
                                    Image(
                                        systemName: selectedAccountIds.contains(account.id) ?
                                            "checkmark.square.fill" : "square",
                                    )
                                    .foregroundColor(
                                        selectedAccountIds.contains(account.id) ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.username)
                                            .foregroundColor(.primary)
                                        Text(account.brandEnum.displayName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    } header: {
                        HStack {
                            Text("Accounts")
                            Spacer()
                            Button("All") {
                                selectedAccountIds = Set(allAccounts.map(\.id))
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            Button("None") {
                                selectedAccountIds = []
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Filter Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
