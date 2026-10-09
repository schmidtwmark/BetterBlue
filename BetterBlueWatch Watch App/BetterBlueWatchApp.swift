//
//  BetterBlueWatchApp.swift
//  BetterBlueWatch Watch App
//
//  Created by Mark Schmidt on 8/28/25.
//

import BetterBlueKit
import Foundation
import SwiftData
import SwiftUI

extension Notification.Name {
    static let fakeAccountConfigurationChanged = Notification.Name("FakeAccountConfigurationChanged")
}

@main
struct BetterBlueWatchApp: App {
    var sharedModelContainer: ModelContainer = {
        // Spin up the CloudKit sync monitor BEFORE creating the
        // container so we catch the initial `setup` events that
        // fire as SwiftData wires up its NSPersistentCloudKitContainer.
        // The watch is where sync visibility matters most — it's
        // the platform with the most reports of "Not Syncing."
        Task { @MainActor in _ = CloudKitSyncMonitor.shared }

        do {
            let container = try createSharedModelContainer()

            // Configure the HTTP log sink manager for watch
            HTTPLogSinkManager.shared.configure(with: container, deviceType: .watch)
            Task { @MainActor in WatchComplicationReloader.observeCloudKitImports(in: container) }

            print("✅ [WatchApp] Created shared ModelContainer")
            return container
        } catch {
            print("❌ [WatchApp] Failed to create ModelContainer: \(error)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}

extension BetterBlueWatchApp {
    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .modifier(ComplicationReloadOnBackground())
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Catch-all for edits no explicit path reloads for (a status poll the
/// user wrist-downed out of, say): flush them and refresh the
/// complication on the way out, if it would change.
private struct ComplicationReloadOnBackground: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .background {
                WatchComplicationReloader.reloadIfChanged(modelContext)
            }
        }
    }
}
