//
//  HTTPLogSinkManager.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/11/25.
//

import BetterBlueKit
import Foundation
import SwiftData

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#elseif os(watchOS)
    import WatchKit
#endif

@MainActor
class HTTPLogSinkManager {
    static let shared = HTTPLogSinkManager()
    private var modelContainer: ModelContainer?
    private var deviceType: DeviceType?

    private init() {}

    func configure(with container: ModelContainer, deviceType: DeviceType) {
        modelContainer = container
        self.deviceType = deviceType
    }

    func createLogSink() -> HTTPLogSink? {
        guard let modelContainer, let deviceType else { return nil }

        return { httpLog in
            Task { @MainActor in
                let context = modelContainer.mainContext
                let bbHttpLog = BBHTTPLog(log: httpLog, deviceType: deviceType)
                context.insert(bbHttpLog)

                do {
                    try context.save()

                    // Clean up old logs to maintain a soft limit of 100 logs
                    try await self.cleanupOldLogs(context: context)
                } catch {
                    print("🔴 [HTTPLog] Failed to save HTTP log: \(error)")
                }
            }
        }
    }

    private func cleanupOldLogs(context: ModelContext) async throws {
        let logCountDescriptor = FetchDescriptor<BBHTTPLog>()
        let allLogs = try context.fetch(logCountDescriptor)

        let maxLogs = 100
        if allLogs.count > maxLogs {
            // Sort logs by timestamp (oldest first) and get the excess logs to delete
            let sortedLogs = allLogs.sorted { $0.log.timestamp < $1.log.timestamp }
            let logsToDelete = sortedLogs.prefix(allLogs.count - maxLogs)

            for logToDelete in logsToDelete {
                context.delete(logToDelete)
            }

            try context.save()
            print("🧹 [HTTPLog] Cleaned up \(logsToDelete.count) old logs (keeping \(maxLogs) most recent)")
        }
    }

    static func detectMainAppDeviceType() -> DeviceType {
        #if os(macOS)
            return .mac
        #elseif os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                return .iPad
            } else {
                return .iPhone
            }
        #else
            return .iPhone
        #endif
    }
}
