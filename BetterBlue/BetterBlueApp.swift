//
//  BetterBlueApp.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 6/12/25.
//

import AppIntents
import BetterBlueKit
import CloudKit
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

    /// Holds the result of the container init — either the actual
    /// `ModelContainer` (success path) or a `String` describing why
    /// we couldn't build one. Replaces a `fatalError` that was
    /// observed crashing real TestFlight users one second after
    /// launch when `createSharedModelContainer()` happened to throw
    /// (transient iCloud availability, App Group container not
    /// ready yet, SQLite migration in progress, …). Crashing in
    /// that situation guaranteed every subsequent launch would
    /// crash too until the underlying condition cleared — bad UX
    /// when a polite error screen lets the user retry.
    enum ContainerResult {
        case ready(ModelContainer)
        case failed(String)
    }

    let containerResult: ContainerResult = {
        // Configure BetterBlueKit to use OSLog via AppLogger
        BBLogger.sink = OSLogSink.shared

        // Spin up the CloudKit sync monitor BEFORE creating the
        // container so we catch the initial `setup` event(s) that
        // fire as SwiftData wires up its NSPersistentCloudKitContainer.
        // Without this, the Diagnostics view shows "Last setup:
        // never" even on a healthy launch.
        Task { @MainActor in _ = CloudKitSyncMonitor.shared }

        do {
            let container = try createSharedModelContainer()
            appModelContainer = container

            // Configure the HTTP log sink manager with auto-detected device type
            let deviceType = HTTPLogSinkManager.detectMainAppDeviceType()
            HTTPLogSinkManager.shared.configure(with: container, deviceType: deviceType)

            // Order matters: purge zombie vehicles first so their cascaded
            // presets are removed, then collapse duplicate VINs (which
            // only considers vehicles that still have an account), *then*
            // sweep up any presets still left dangling (which can happen
            // independently via an interrupted delete on an earlier schema).
            cleanupOrphanedVehicles(container: container)
            cleanupDuplicateVehicles(container: container)
            cleanupOrphanedClimatePresets(container: container)

            return .ready(container)
        } catch {
            BBLogger.error(.app, "Failed to create ModelContainer: \(error)")
            return .failed(error.localizedDescription)
        }
    }()

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .ready(let container):
                MainView()
                    .onOpenURL { url in
                        handleDeepLink(url)
                    }
                    .modelContainer(container)
            case .failed(let reason):
                ContainerFailureView(reason: reason)
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        BBLogger.info(.app, "[SVI] handleDeepLink \(url.absoluteString)")
        guard url.scheme == "betterblue" else { return }

        let pathComponents = url.pathComponents.dropFirst() // Drop the leading "/"

        if url.host == "vehicle",
           let vin = pathComponents.first {
            BBLogger.info(.app, "[SVI] handleDeepLink posting .selectVehicle vin=\(vin)")
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

    /// Resolves the deep-link `ModelContext`. Returns nil when the
    /// container couldn't be created at launch — in that case the
    /// app is showing `ContainerFailureView`, so there's nothing
    /// useful we can do with the deep link anyway.
    private var deepLinkContext: ModelContext? {
        if case .ready(let container) = containerResult {
            return container.mainContext
        }
        return nil
    }

    private func handleStartClimate(vin: String, presetId: UUID?, presetName: String?, presetIcon: String?) {
        Task { @MainActor in
            do {
                guard let context = deepLinkContext else { return }

                var descriptor = FetchDescriptor<BBVehicle>(predicate: #Predicate { $0.vin == vin })
                descriptor.fetchLimit = 1

                guard let vehicle = try? context.fetch(descriptor).first,
                      let account = vehicle.account else {
                    AppLogger.app.error("DeepLink: Vehicle not found for startClimate: \(vin)")
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

                let preset = presetName ?? "default"
                AppLogger.app.info("DeepLink: Starting climate for \(vehicle.displayName) with preset: \(preset)")
                try await account.startClimate(
                    vehicle,
                    options: options,
                    modelContext: context,
                    presetName: presetName,
                    presetIcon: presetIcon
                )
            } catch {
                AppLogger.app.error("DeepLink: Failed to start climate: \(error)")
            }
        }
    }

    private func handleStartCharge(vin: String) {
        Task { @MainActor in
            do {
                guard let context = deepLinkContext else { return }

                var descriptor = FetchDescriptor<BBVehicle>(predicate: #Predicate { $0.vin == vin })
                descriptor.fetchLimit = 1

                guard let vehicle = try? context.fetch(descriptor).first,
                      let account = vehicle.account else {
                    AppLogger.app.error("DeepLink: Vehicle not found for startCharge: \(vin)")
                    return
                }

                AppLogger.app.info("DeepLink: Starting charge for \(vehicle.displayName)")
                try await account.startCharge(vehicle, modelContext: context)
            } catch {
                AppLogger.app.error("DeepLink: Failed to start charge: \(error)")
            }
        }
    }
}

@MainActor
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions and register for remote notifications
        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let granted = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            AppLogger.push.info("AppDelegate: Notification permissions granted: \(granted ?? false)")

            // Register for remote notifications to receive background wakeups
            application.registerForRemoteNotifications()
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppLogger.push.info("Received device token: \(tokenString.prefix(20), privacy: .public)...")
        LiveActivityManager.shared.setDeviceToken(tokenString)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLogger.push.error("Failed to register for remote notifications: \(error)")
    }

    // Handle background push notifications for Live Activity wakeup
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        AppLogger.push.info("Received remote notification: \(userInfo, privacy: .public)")
        // Taken here, synchronously, where background time is still
        // guaranteed. Pushes are when the app runs in the background, and
        // CloudKit writes to the App Group store for a while after each
        // one; a write still under way when the app is suspended gets it
        // killed (0xdead10cc). Keep the app awake until it's done, within
        // the ~30 s a push allows.
        let backgroundTask = BackgroundTask(name: "BetterBlue.push")
        let deadline = ContinuousClock.now + .seconds(25)

        if userInfo["liveActivityWakeup"] != nil {
            AppLogger.push.info("Processing Live Activity wakeup push")
            Task {
                await LiveActivityManager.shared.handleWakeupPush()
                // The wakeup's save sets off a CloudKit export.
                await CloudKitSyncMonitor.shared.waitUntilIdle(deadline: deadline)
                completionHandler(.newData)
                backgroundTask.end()
            }
        } else if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            // A change from another device: Core Data imports it.
            Task {
                await CloudKitSyncMonitor.shared.waitUntilIdle(grace: .seconds(2), deadline: deadline)
                completionHandler(.newData)
                backgroundTask.end()
            }
        } else {
            completionHandler(.noData)
            backgroundTask.end()
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
        // Handle notification tap - navigate to vehicle if VIN provided.
        // Project the Sendable bits out before crossing the actor
        // boundary — `UNNotificationResponse` itself isn't Sendable.
        if let vin = response.notification.request.content.userInfo["vin"] as? String {
            let notificationId = response.notification.request.identifier
            Task { @MainActor in
                BBLogger.info(.app, "[SVI] push-notification tap posting .selectVehicle vin=\(vin) (notificationId=\(notificationId))")
                NotificationCenter.default.post(name: .selectVehicle, object: vin)
            }
        }
        completionHandler()
    }
}

/// A `UIApplication` background task: asks for background time on
/// creation and gives it back on `end()` — or when the time runs out,
/// which iOS requires to happen right away. Safe to end more than once.
@MainActor
final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Shown when `createSharedModelContainer()` throws at launch.
/// Used to be a `fatalError`, which guaranteed the app would
/// crash one second after launch every time until the underlying
/// condition cleared. A polite error screen with a retry button
/// is a much better failure mode — the user can at least kill +
/// relaunch the app explicitly once they fix whatever was wrong
/// (e.g. signed back into iCloud), and the bug report sent in
/// from this screen is more actionable than a SIGTRAP.
struct ContainerFailureView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Couldn't Load Your Data")
                .font(.title2)
                .fontWeight(.semibold)
            Text("BetterBlue couldn't open its local data store. This usually clears up after signing back into iCloud or restarting the device.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Surface the raw error so the user can include it in a
            // bug report. Read-only, selectable, monospaced so we
            // recognize it instantly when it lands in our inbox.
            ScrollView {
                Text(reason)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                exit(0)
            } label: {
                Text("Quit")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

