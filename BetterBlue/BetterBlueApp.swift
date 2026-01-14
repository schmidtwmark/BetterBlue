//
//  BetterBlueApp.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 6/12/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let fakeAccountConfigurationChanged = Notification.Name("FakeAccountConfigurationChanged")
    static let selectVehicle = Notification.Name("SelectVehicle")
}

@main
struct BetterBlueApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        do {
            let container = try createSharedModelContainer()

            // Configure the HTTP log sink manager with auto-detected device type
            let deviceType = HTTPLogSinkManager.detectMainAppDeviceType()
            HTTPLogSinkManager.shared.configure(with: container, deviceType: deviceType)

            return container
        } catch {
            print("💥 [MainApp] Failed to create ModelContainer: \(error)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainView()
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "betterblue" else { return }

        let pathComponents = url.pathComponents.dropFirst() // Drop the leading "/"

        if url.host == "vehicle",
           let vin = pathComponents.first {
            NotificationCenter.default.post(
                name: .selectVehicle,
                object: vin,
            )
        } else if url.host == "startClimate",
                  let vin = pathComponents.first {
            // Handle climate start from Control Center
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let presetId = queryItems?.first(where: { $0.name == "presetId" })?.value.flatMap { UUID(uuidString: $0) }
            let presetName = queryItems?.first(where: { $0.name == "presetName" })?.value
            let presetIcon = queryItems?.first(where: { $0.name == "presetIcon" })?.value

            handleStartClimate(vin: vin, presetId: presetId, presetName: presetName, presetIcon: presetIcon)
        } else if url.host == "startCharge",
                  let vin = pathComponents.first {
            // Handle charge start from Control Center
            handleStartCharge(vin: vin)
        }
    }

    private func handleStartClimate(vin: String, presetId: UUID?, presetName: String?, presetIcon: String?) {
        Task { @MainActor in
            do {
                let context = sharedModelContainer.mainContext

                var descriptor = FetchDescriptor<BBVehicle>(predicate: #Predicate { $0.vin == vin })
                descriptor.fetchLimit = 1

                guard let vehicle = try? context.fetch(descriptor).first,
                      let account = vehicle.account else {
                    print("❌ [DeepLink] Vehicle not found for startClimate: \(vin)")
                    return
                }

                // Get climate options from preset if available
                var options: ClimateOptions?
                if let presetId {
                    let presetPredicate = #Predicate<ClimatePreset> { $0.id == presetId }
                    let presetDescriptor = FetchDescriptor(predicate: presetPredicate)
                    if let preset = try? context.fetch(presetDescriptor).first {
                        options = preset.climateOptions
                    }
                }

                print("🚗 [DeepLink] Starting climate for \(vehicle.displayName) with preset: \(presetName ?? "default")")
                try await account.startClimate(
                    vehicle,
                    options: options,
                    modelContext: context,
                    presetName: presetName,
                    presetIcon: presetIcon
                )
            } catch {
                print("❌ [DeepLink] Failed to start climate: \(error)")
            }
        }
    }

    private func handleStartCharge(vin: String) {
        Task { @MainActor in
            do {
                let context = sharedModelContainer.mainContext

                var descriptor = FetchDescriptor<BBVehicle>(predicate: #Predicate { $0.vin == vin })
                descriptor.fetchLimit = 1

                guard let vehicle = try? context.fetch(descriptor).first,
                      let account = vehicle.account else {
                    print("❌ [DeepLink] Vehicle not found for startCharge: \(vin)")
                    return
                }

                print("🔌 [DeepLink] Starting charge for \(vehicle.displayName)")
                try await account.startCharge(vehicle, modelContext: context)
            } catch {
                print("❌ [DeepLink] Failed to start charge: \(error)")
            }
        }
    }
}

@MainActor
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions and register for remote notifications
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            print("📲 [AppDelegate] Notification permissions granted: \(granted ?? false)")

            // Register for remote notifications to receive background wakeups
            application.registerForRemoteNotifications()
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("📲 [AppDelegate] Received device token: \(tokenString.prefix(20))...")
        LiveActivityManager.shared.setDeviceToken(tokenString)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ [AppDelegate] Failed to register for remote notifications: \(error)")
    }

    // Handle background push notifications for Live Activity wakeup
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("📲 [AppDelegate] Received remote notification: \(userInfo)")

        // Check if this is a Live Activity wakeup
        if userInfo["liveActivityWakeup"] != nil {
            Task {
                await LiveActivityManager.shared.handleWakeupPush()
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }

    // Allow notifications to show when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification tap - navigate to vehicle if VIN provided
        if let vin = response.notification.request.content.userInfo["vin"] as? String {
            Task { @MainActor in
                NotificationCenter.default.post(name: .selectVehicle, object: vin)
            }
        }
        completionHandler()
    }
}
