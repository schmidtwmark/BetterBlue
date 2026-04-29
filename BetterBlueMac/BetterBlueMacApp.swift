//
//  BetterBlueMacApp.swift
//  BetterBlueMac
//
//  Native macOS entry point. Four scenes:
//
//    1. The main window (`MainView`, the same SwiftUI used on iPad).
//    2. A native `Settings` scene — auto-creates the "Settings…" item
//       under the app menu with the standard ⌘, shortcut.
//    3. A separate `WindowGroup(id: "settings")` for the same content,
//       so cross-platform call sites that use
//       `openWindow(id: "settings")` keep working.
//    4. A `MenuBarExtra` for the menu bar dropdown using the shared
//       `MenuBarPanelContent` SwiftUI view.
//
//  All scenes attach `.modelContainer(sharedModelContainer)` so SwiftData
//  `@Query` works in every window — including the menu bar's popover.
//

import BetterBlueKit
import SwiftData
import SwiftUI

@main
struct BetterBlueMacApp: App {
    @State private var appSettings = AppSettings.shared

    var sharedModelContainer: ModelContainer = {
        BBLogger.sink = OSLogSink.shared

        do {
            let container = try createSharedModelContainer()
            let deviceType = HTTPLogSinkManager.detectMainAppDeviceType()
            HTTPLogSinkManager.shared.configure(with: container, deviceType: deviceType)

            cleanupOrphanedVehicles(container: container)
            cleanupOrphanedClimatePresets(container: container)

            return container
        } catch {
            BBLogger.error(.app, "Failed to create ModelContainer: \(error)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Main window. `.windowStyle(.hiddenTitleBar)` removes the title
        // text and merges the title bar into the toolbar — the standard
        // Mail / Music chrome where the stoplights float over the
        // sidebar background. Min size sized so the bottom-trailing
        // controls overlay never covers where the map pin renders.
        WindowGroup {
            MainView()
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    MenuBarRefreshManager.shared.configure(modelContainer: sharedModelContainer)
                    if appSettings.menuBarEnabled {
                        MenuBarRefreshManager.shared.start()
                    }
                }
                .onChange(of: appSettings.menuBarEnabled) { _, newValue in
                    if newValue {
                        MenuBarRefreshManager.shared.start()
                    } else {
                        MenuBarRefreshManager.shared.stop()
                    }
                }
                .onChange(of: appSettings.widgetRefreshInterval) { _, _ in
                    MenuBarRefreshManager.shared.intervalDidChange()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {} // No "New Window" menu item
        }

        // Native macOS Settings scene — appears as "Settings…" under the
        // app menu with the standard ⌘, shortcut. `.hiddenTitleBar`
        // collapses the title strip so the stoplights sit on the
        // sidebar background, matching the System Settings look.
        Settings {
            SettingsView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)

        // Same SettingsView reachable via `openWindow(id: "settings")`
        // for cross-platform parity with the iOS path.
        WindowGroup(id: "settings") {
            SettingsView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)

        // Menu bar dropdown. `isInserted` lets the user toggle the
        // status item on/off via the Settings → Menu Bar toggle.
        // `.modelContainer` is applied to the scene so the
        // popover's `@Query` finds the SwiftData store.
        MenuBarExtra(isInserted: $appSettings.menuBarEnabled) {
            MenuBarPanelContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(sharedModelContainer)
    }
}

/// Tiny wrapper view so we can use `@Query` to pick the first
/// vehicle's `menuBarIconName` for the status bar icon.
private struct MenuBarLabel: View {
    @Query(filter: #Predicate<BBVehicle> { !$0.isHidden },
           sort: \BBVehicle.sortOrder)
    private var vehicles: [BBVehicle]

    var body: some View {
        Image(systemName: vehicles.first?.menuBarIconName ?? "car.fill")
    }
}
