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

/// Nonisolated namespace for the TaskLocal override. Lives outside of
/// `HTTPLogSinkManager` because the manager is `@MainActor`-isolated and
/// its statics can't be read from the Sendable closure that `createLogSink`
/// returns. Wrap a call site in
/// `HTTPLogContext.$overrideDeviceType.withValue(.menuBar) { ... }` to tag
/// every HTTP request made in that task (and its async children) with
/// the given `DeviceType`. Used by `MenuBarRefreshManager` (MAR-54) so
/// its periodic polls appear as `.menuBar` in the HTTP Logs view without
/// forcing `BBAccount` to re-initialize its API client.
/// Marked `nonisolated` so its `@TaskLocal` storage isn't pulled into
/// the macOS target's default-MainActor isolation domain. TaskLocals
/// are intrinsically task-bound (not actor-bound), so MainActor would
/// only get in the way — the read inside the HTTP-log sink's
/// `@Sendable` closure happens on whatever task the request completes
/// on, not necessarily MainActor.
nonisolated enum HTTPLogContext {
    @TaskLocal static var overrideDeviceType: DeviceType?
}

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
            // Capture the TaskLocal override (if any) synchronously, before
            // hopping into `Task.detached` — which doesn't inherit
            // TaskLocals. Callers that want to tag a batch of requests
            // with a different DeviceType wrap their work in
            // `HTTPLogSinkManager.$overrideDeviceType.withValue(...)`; see
            // `MenuBarRefreshManager` for the canonical use.
            let effectiveDeviceType = HTTPLogContext.overrideDeviceType ?? deviceType

            // Use detached task to prevent crashes if widget is killed
            Task.detached {
                let debugModeEnabled = await AppSettings.shared.debugModeEnabled
                guard debugModeEnabled else { return }

                do {
                    // Create a background context to avoid blocking the main thread
                    let context = ModelContext(modelContainer)
                    let bbHttpLog = BBHTTPLog(log: httpLog, deviceType: effectiveDeviceType)
                    context.insert(bbHttpLog)

                    try context.save()

                    // Only clean up for non-widget contexts to avoid extended processing
                    if effectiveDeviceType != .widget && effectiveDeviceType != .liveActivity {
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
