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
        do {
            let container = try createSharedModelContainer()

            // Configure the HTTP log sink manager for watch
            HTTPLogSinkManager.shared.configure(with: container, deviceType: .watch)

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
        }
        .modelContainer(sharedModelContainer)
    }
}
