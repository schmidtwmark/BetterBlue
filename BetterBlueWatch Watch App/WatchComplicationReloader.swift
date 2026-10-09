//
//  WatchComplicationReloader.swift
//  BetterBlueWatch Watch App
//
//  Keeps the watch-face complication in step with the shared store.
//

import BetterBlueKit
import CoreData
import SwiftData
import WidgetKit

/// The complication extension reads the store from disk in its own
/// process, so a reload only helps once the new status is saved. Asking
/// before SwiftData's autosave lands re-renders the old value, and
/// watchOS may not offer another reload for a long while — the
/// complication that "never updates" (GitHub #112).
@MainActor
enum WatchComplicationReloader {
    /// What the complication was last asked to show. `nil` until the
    /// first reload in this process, so that one always goes out.
    private static var lastContent: WatchComplicationEntry.Content?
    private static var importObserver: NSObjectProtocol?

    /// After a refresh or command the user is waiting on: save, then
    /// always reload. Foreground reloads don't count against the budget.
    static func saveAndReload(_ context: ModelContext) {
        save(context)
        lastContent = content(of: context.container)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Background paths (CloudKit imports, leaving the app): reloads are
    /// budgeted there and most imports are HTTP logs, so only spend one
    /// when the complication would actually draw something different.
    static func reloadIfChanged(_ context: ModelContext) {
        save(context)
        let content = content(of: context.container)
        guard content != lastContent else { return }
        lastContent = content
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Status refreshed on the phone reaches the watch as a CloudKit
    /// import, and nothing else would tell the complication about it.
    static func observeCloudKitImports(in container: ModelContainer) {
        guard importObserver == nil else { return }
        importObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { note in
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let event = note.userInfo?[key] as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil, event.succeeded else { return }
            MainActor.assumeIsolated {
                reloadIfChanged(container.mainContext)
            }
        }
    }

    private static func save(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            BBLogger.warning(.app, "WatchComplicationReloader: save before reload failed: \(error)")
        }
    }

    /// Read through a fresh context: it sees what's on disk — what the
    /// extension will see — including imports the main context hasn't
    /// merged yet.
    private static func content(of container: ModelContainer) -> WatchComplicationEntry.Content? {
        try? WatchComplicationProvider.entry(in: ModelContext(container)).content
    }
}
