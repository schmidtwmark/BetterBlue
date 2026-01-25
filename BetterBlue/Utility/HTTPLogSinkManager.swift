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
        guard let deviceType else { return nil }
        return createLogSink(for: deviceType)
    }

    func createLogSink(for deviceType: DeviceType) -> HTTPLogSink? {
        guard let modelContainer else { return nil }

        return { httpLog in
            // Use detached task to prevent crashes if widget is killed
            Task.detached {
                let debugModeEnabled = await AppSettings.shared.debugModeEnabled
                guard debugModeEnabled else { return }

                do {
                    // Create a background context to avoid blocking the main thread
                    let context = ModelContext(modelContainer)
                    let bbHttpLog = BBHTTPLog(log: httpLog, deviceType: deviceType)
                    context.insert(bbHttpLog)

                    try context.save()

                    // Only clean up for non-widget contexts to avoid extended processing
                    if deviceType != .widget && deviceType != .liveActivity {
                        try await self.cleanupOldLogs(context: context)
                    }
                } catch {
                    // Silently fail for widgets to prevent crashes
                    BBLogger.error(.app, "HTTPLog: Failed to save HTTP log: \(error)")
                }
            }
        }
    }

    private func cleanupOldLogs(context: ModelContext) async throws {
        let logCountDescriptor = FetchDescriptor<BBHTTPLog>()
        let allLogs = try context.fetch(logCountDescriptor)

        let maxLogs = 100
        let deleteThreshold = 50
        if allLogs.count > maxLogs {
            // Sort logs by timestamp (oldest first) and delete oldest 50
            let sortedLogs = allLogs.sorted { $0.log.timestamp < $1.log.timestamp }
            let logsToDelete = sortedLogs.prefix(deleteThreshold)

            for logToDelete in logsToDelete {
                context.delete(logToDelete)
            }

            try context.save()
            BBLogger.info(.app, "HTTPLog: Cleaned up \(logsToDelete.count) old logs (now have \(allLogs.count - deleteThreshold) logs)")
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
