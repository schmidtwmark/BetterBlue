//
//  LiveActivityManager.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 12/13/25.
//

#if canImport(ActivityKit)
import ActivityKit
#endif
import BetterBlueKit
import Foundation
import OSLog
import SwiftData
import UIKit
import WidgetKit

#if DEBUG
private let liveActivityBackendURL = "https://phgu023o97.execute-api.us-east-1.amazonaws.com/dev"
#else
private let liveActivityBackendURL = "https://6rx06wxs8f.execute-api.us-east-1.amazonaws.com/prod"
#endif

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var deviceToken: String?
    private var isRegisteredWithBackend = false
    private var isObservingPushToStartTokens = false

    /// How long an update's numbers count as current. Charging wakeups
    /// come every 5 minutes, so this is several missed in a row. Past it,
    /// iOS marks the card stale (`context.isStale`) and it greys out
    /// instead of passing a frozen reading off as live. Wakeups can stop
    /// with nothing on the phone running to say so: iOS throttles or drops
    /// background pushes, the backend expires its row after 8 hours, and a
    /// force-quit app isn't woken at all.
    nonisolated static let staleInterval: TimeInterval = 25 * 60

    /// The stale date for content carrying a fresh status.
    nonisolated static func freshStaleDate() -> Date {
        Date().addingTimeInterval(staleInterval)
    }

    /// The stale date for content showing `status`. A car waiting for its
    /// schedule stays accurate until the charge is due, so its card goes
    /// stale only once that time has passed without an update.
    nonisolated static func staleDate(for status: VehicleStatus, now: Date = Date()) -> Date {
        guard let ev = status.evStatus, ev.isWaitingForScheduledCharge else {
            return now.addingTimeInterval(staleInterval)
        }
        guard let start = ev.expectedChargeStart(after: now) else {
            return now.addingTimeInterval(2 * 3600)
        }
        return max(start, now).addingTimeInterval(staleInterval)
    }

    /// A card that has been up this long is replaced, not updated, when
    /// its car goes from waiting to charging. ActivityKit ends every
    /// Live Activity 8 hours after it starts, so a card started at 6 PM
    /// for an 11:30 PM charge would otherwise vanish mid-charge at 2 AM.
    private static let replaceWaitingCardAfter: TimeInterval = 3600

    private init() {}

    func setDeviceToken(_ token: String) {
        deviceToken = token
        AppLogger.liveActivity.info("Device token set: \(token.prefix(20), privacy: .public)...")

        // If we have active Live Activities, register with backend now
        #if canImport(ActivityKit)
        if let activity = Activity<VehicleActivityAttributes>.activities.first, !isRegisteredWithBackend {
            let state = activity.content.state
            Task {
                await registerWithBackend(activityType: state.activityType, startAt: Self.wakeupStart(for: state.status))
            }
        }
        #endif
        Task { await syncNightlyCheck() }
    }

    // MARK: - Lookup

    #if canImport(ActivityKit)
    /// The card for a vehicle. Cards started by a push carry no VIN in
    /// their attributes (nothing identifying goes through the backend),
    /// so those match on the VIN in their content or the vehicle's id.
    nonisolated static func activity(forVIN vin: String, vehicleId: UUID? = nil) -> Activity<VehicleActivityAttributes>? {
        Activity<VehicleActivityAttributes>.activities.first { activity in
            if activity.attributes.vin == vin, !vin.isEmpty { return true }
            guard activity.attributes.vin.isEmpty else { return false }
            if !vin.isEmpty, activity.content.state.status.vin == vin { return true }
            return vehicleId != nil && activity.attributes.vehicleId == vehicleId
        }
    }
    #endif

    /// What the manager needs to know about a vehicle outside a
    /// SwiftData scope.
    struct VehicleSnapshot: Sendable {
        let id: UUID
        let vin: String
        let displayName: String
        let chargingColorName: String?

        @MainActor init(_ vehicle: BBVehicle) {
            id = vehicle.id
            vin = vehicle.vin
            displayName = vehicle.displayName
            chargingColorName = vehicle.chargingColorName
        }
    }

    // MARK: - Wakeup pushes

    /// Handle a wakeup push from the backend - fetch fresh data and update all Live Activities
    ///
    /// Restructured to minimise SwiftData lock hold time during the
    /// background wakeup window. The old shape held the container's
    /// `mainContext` for the entire loop body, which kept a SQLite
    /// connection live across multiple seconds of HTTP — exactly the
    /// pattern that trips RunningBoard's 0xdead10cc kill if iOS
    /// suspends us mid-request. The new shape:
    ///
    ///   1. Snapshots only the active live-activity VINs (Sendable
    ///      strings) so we don't iterate `Activity.activities` from
    ///      inside a SwiftData scope.
    ///   2. For each VIN, opens a *fresh* `ModelContext` in a tight
    ///      `do { … }` block. Fetch → HTTP → save → drop. SwiftData
    ///      releases that context's tracking state at scope exit;
    ///      saves complete promptly because change sets are small.
    ///   3. Saves explicitly with `try context.save()` so writes flush
    ///      before the context drops (the default fresh context does
    ///      not autosave the way `mainContext` does).
    ///   4. Defers the `refreshActivity(…)` ActivityKit update until
    ///      *after* the SwiftData scope, so there's no chance of the
    ///      live-activity push holding open the SQLite connection.
    func handleWakeupPush() async {
        AppLogger.liveActivity.info("Handling wakeup push...")

        #if canImport(ActivityKit)
        // Snapshot just the identifiers — Sendable values — so iteration
        // happens outside any SwiftData scope. A push-started card that
        // hasn't been filled in yet has neither VIN; its vehicle id finds it.
        let targets = Activity<VehicleActivityAttributes>.activities.map { activity in
            (
                vin: activity.attributes.vin.isEmpty ? activity.content.state.status.vin : activity.attributes.vin,
                vehicleId: activity.attributes.vehicleId
            )
        }
        guard !targets.isEmpty else {
            AppLogger.liveActivity.info("No active Live Activities to update")
            return
        }

        guard let container = Self.backgroundContainer() else {
            AppLogger.liveActivity.error("Failed to create model container")
            return
        }

        for target in targets {
            AppLogger.liveActivity.info("Updating Live Activity for VIN: \(target.vin.prefix(8), privacy: .public)...")

            // Per-iteration scope: fresh context, save, drop at end.
            // ActivityKit work happens outside the per-iteration context
            // scope so the push doesn't extend the SwiftData lock-hold window.
            do {
                if let fetched = try await updateVehicleStatus(
                    vin: target.vin, vehicleId: target.vehicleId, container: container
                ) {
                    // Authoritative: only refresh when this fetch confirms the
                    // vehicle is still in the activity's state; otherwise end the
                    // activity so the backend stops waking us (BetterBlue#88).
                    await refreshOrRetireActivity(for: fetched.1, status: fetched.0)
                } else {
                    // No vehicle/account for this VIN — the activity is orphaned
                    // (e.g. the vehicle was removed). End it so wakeups stop.
                    await retireActivity(forVIN: target.vin, vehicleId: target.vehicleId, reason: "vehicle or account not found")
                }
            } catch {
                AppLogger.liveActivity.error(
                    "Error updating Live Activity for \(target.vin.prefix(8), privacy: .public): \(error)"
                )
                // A permanently-broken session fails identically on every 1/min
                // wakeup forever — the background CPU/battery drain in #88. Retire
                // the activity so the push stream stops; transient errors (server
                // hiccup, network blip) are left alone to retry on the next push.
                if Self.isUnrecoverableWakeupError(error) {
                    await retireActivity(forVIN: target.vin, vehicleId: target.vehicleId, reason: "session unrecoverable")
                }
            }
        }
        #endif
    }

    /// Max number of 1/min background wakeups before an activity is force-ended
    /// regardless of reported state — a safety net so a stuck or stale
    /// "charging" status can't keep the wakeup-push loop alive forever (#88).
    /// Set well beyond any realistic charge session (~24h at one wakeup/minute).
    private static let maxWakeups = 1440

    /// Refresh the activity **only** if this wakeup's fresh status confirms
    /// the vehicle is still in the activity's state; otherwise end it.
    /// Being authoritative here — rather than trusting the
    /// `updateActivity` side-effect inside `fetchVehicleStatus` — closes the
    /// window where a just-ended activity could be revived by a blind refresh.
    private func refreshOrRetireActivity(for vehicle: VehicleSnapshot, status: VehicleStatus) async {
        #if canImport(ActivityKit)
        guard let activity = Self.activity(forVIN: vehicle.vin, vehicleId: vehicle.id) else {
            return // already ended (e.g. charging stopped -> updateActivity ended it)
        }

        let state = activity.content.state
        let stillLive: Bool
        switch state.activityType {
        case .charging:
            // Waiting for the schedule keeps a charging card: the charge
            // is coming, and the card says when.
            stillLive = status.evStatus?.charging == true || status.evStatus?.isWaitingForScheduledCharge == true
        case .climate: stillLive = status.climateStatus.airControlOn
        case .debug: stillLive = true // manually controlled; never auto-end
        case .none: stillLive = false
        }

        guard stillLive else {
            await retireActivity(forVIN: vehicle.vin, vehicleId: vehicle.id, reason: "vehicle no longer in activity state")
            return
        }
        guard state.wakeupCount < Self.maxWakeups else {
            await retireActivity(forVIN: vehicle.vin, vehicleId: vehicle.id, reason: "exceeded max wakeups")
            return
        }

        if Self.shouldReplace(state: state, with: status),
           await replaceFromBackground(activity, vehicle: vehicle, status: status) {
            return
        }

        await refreshActivity(for: vehicle.vin, vehicleId: vehicle.id, status: status, incrementWakeup: true, vehicle: vehicle)
        AppLogger.liveActivity.info("Updated Live Activity for \(vehicle.vin.prefix(8), privacy: .public)")
        #endif
    }

    #if canImport(ActivityKit)
    /// A waiting card that has just seen its car start charging, and has
    /// been up long enough that ActivityKit's 8-hour limit would cut the
    /// charge short.
    private static func shouldReplace(state: VehicleActivityAttributes.ContentState, with status: VehicleStatus) -> Bool {
        guard state.activityType == .charging,
              state.status.evStatus?.isWaitingForScheduledCharge == true,
              status.evStatus?.charging == true else { return false }
        let startedAt = state.startedAt ?? .distantPast
        return Date().timeIntervalSince(startedAt) > replaceWaitingCardAfter
    }

    /// Swaps an old card for a fresh one while the app is in the
    /// background, where it can't start one itself: the backend starts it
    /// with a push. Returns false (leaving the old card alone) if no new
    /// card turns up.
    private func replaceFromBackground(
        _ old: Activity<VehicleActivityAttributes>,
        vehicle: VehicleSnapshot,
        status: VehicleStatus
    ) async -> Bool {
        nonisolated(unsafe) let old = old
        guard let fresh = await startActivityByPush(for: vehicle, status: status, excluding: old.id) else {
            return false
        }
        AppLogger.liveActivity.info("Replaced waiting Live Activity \(old.id, privacy: .public) with \(fresh.id, privacy: .public)")
        await old.end(nil, dismissalPolicy: .immediate)
        return true
    }
    #endif

    /// End a Live Activity and, if it was the last one, unregister from the
    /// backend so it stops sending wakeup pushes.
    private func retireActivity(forVIN vin: String, vehicleId: UUID?, reason: String) async {
        #if canImport(ActivityKit)
        guard let existingActivity = Self.activity(forVIN: vin, vehicleId: vehicleId) else {
            return
        }
        AppLogger.liveActivity.info(
            "Retiring Live Activity for \(vin.prefix(8), privacy: .public): \(reason, privacy: .public)"
        )
        nonisolated(unsafe) let activity = existingActivity
        await activity.end(nil, dismissalPolicy: .immediate)
        // `<= 1`: the just-ended activity can still appear in `activities`
        // briefly, so "1 or fewer remaining" means "none left that need pushes."
        if Activity<VehicleActivityAttributes>.activities.count <= 1 {
            await unregisterFromBackend()
        }
        #endif
    }

    /// Whether a wakeup fetch error means the session is permanently broken
    /// (re-login won't help until the user re-authenticates), versus a
    /// transient failure worth retrying on the next push.
    private static func isUnrecoverableWakeupError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError.errorType {
        case .invalidCredentials, .failedRetryLogin:
            return true
        default:
            return false
        }
    }

    /// The app's own container when there is one (always, in the app
    /// process); otherwise one without CloudKit — the app's container
    /// mirrors whatever it saves.
    private static func backgroundContainer() -> ModelContainer? {
        appModelContainer ?? (try? createSharedModelContainer(enableCloudKit: false))
    }

    /// Per-activity SwiftData scope. Opens a fresh `ModelContext`,
    /// fetches the vehicle (by VIN, or by id for a card that doesn't know
    /// its VIN yet), fires the HTTP refresh, persists, and returns the new
    /// status to the caller. The context drops when this function
    /// returns, so SwiftData releases its change-tracking state
    /// immediately rather than carrying it across every other activity in
    /// the same push batch.
    private func updateVehicleStatus(
        vin: String,
        vehicleId: UUID?,
        container: ModelContainer,
        cached: Bool = true
    ) async throws -> (VehicleStatus, VehicleSnapshot)? {
        let context = ModelContext(container)

        var descriptor: FetchDescriptor<BBVehicle>
        if !vin.isEmpty {
            descriptor = FetchDescriptor(predicate: #Predicate<BBVehicle> { $0.vin == vin })
        } else if let vehicleId {
            descriptor = FetchDescriptor(predicate: #Predicate<BBVehicle> { $0.id == vehicleId })
        } else {
            return nil
        }
        descriptor.fetchLimit = 1

        guard let vehicle = try context.fetch(descriptor).first,
              let account = vehicle.account else {
            AppLogger.liveActivity.error("Vehicle or account not found for VIN: \(vin.prefix(8), privacy: .public)")
            return nil
        }

        try await account.initialize(modelContext: context, deviceType: .liveActivity)
        let status = try await account.fetchVehicleStatus(for: vehicle, modelContext: context, cached: cached)

        vehicle.updateStatus(with: status)
        try context.save()
        return (status, VehicleSnapshot(vehicle))
    }

    // MARK: - Foreground updates

    func updateActivity(for vehicle: BBVehicle, status: VehicleStatus, modelContext: ModelContext) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var type: LiveActivityType = .none

        if vehicle.debugLiveActivity {
            type = .debug
        } else if status.evStatus?.charging == true || status.evStatus?.isWaitingForScheduledCharge == true {
            // Waiting for the schedule gets the charging card too, showing
            // when the charge starts.
            type = .charging
        }
        // Note: Climate live activity removed due to infrequent updates making it a poor UX

        if type != .none {
            startOrUpdateActivity(for: vehicle, status: status, type: type)
        } else {
            endActivity(for: vehicle)
        }
        #endif
    }

    nonisolated func refreshActivity(
        for vin: String,
        vehicleId: UUID? = nil,
        status: VehicleStatus,
        incrementWakeup: Bool = false,
        vehicle: VehicleSnapshot? = nil
    ) async {
        #if canImport(ActivityKit)
        guard let existingActivity = Self.activity(forVIN: vin, vehicleId: vehicleId) else {
            return
        }

        var updatedState = existingActivity.content.state
        updatedState.status = status
        updatedState.isRefreshing = false
        if incrementWakeup {
            updatedState.wakeupCount += 1
            updatedState.lastWakeupTime = Date()
        }
        if let vehicle {
            updatedState.vehicleName = vehicle.displayName
            updatedState.chargingColorName = vehicle.chargingColorName
        }

        await existingActivity.update(ActivityContent(state: updatedState, staleDate: Self.staleDate(for: status)))

        // Refresh widgets to stay in sync with live activity
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    nonisolated func setRefreshing(for vin: String, isRefreshing: Bool) async {
        #if canImport(ActivityKit)
        guard let existingActivity = Self.activity(forVIN: vin) else {
            return
        }

        var updatedState = existingActivity.content.state
        updatedState.isRefreshing = isRefreshing

        // Same status as before, so it doesn't get any fresher.
        await existingActivity.update(
            ActivityContent(state: updatedState, staleDate: existingActivity.content.staleDate)
        )
        #endif
    }

    /// Start or stop the debug Live Activity based on the vehicle's debugLiveActivity flag
    func updateDebugActivity(for vehicle: BBVehicle) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if vehicle.debugLiveActivity {
            // Start the debug Live Activity
            guard let status = createStatusFromVehicle(vehicle) else {
                AppLogger.liveActivity.error("Cannot start debug activity: missing vehicle status")
                return
            }
            startOrUpdateActivity(for: vehicle, status: status, type: .debug)
        } else {
            // End the debug Live Activity
            endActivity(for: vehicle)
        }
        #endif
    }

    func startCommandActivity(
        for vehicle: BBVehicle,
        type: LiveActivityType,
        modelContext: ModelContext,
        climatePresetName: String? = nil,
        climatePresetIcon: String? = nil
    ) {
        #if canImport(ActivityKit)
        guard AppSettings.shared.liveActivitiesEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let status = createStatusFromVehicle(vehicle) else { return }

        startOrUpdateActivity(
            for: vehicle,
            status: status,
            type: type,
            climatePresetName: climatePresetName,
            climatePresetIcon: climatePresetIcon
        )

        // Poll for state change in background
        Task {
            var taskId = UIBackgroundTaskIdentifier.invalid
            if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication {
                taskId = app.beginBackgroundTask(withName: "CommandActivityPoll") {
                    // iOS is about to suspend us: end the task now so RunningBoard
                    // doesn't force-kill the app (0xdead10cc). Guard so the `defer`
                    // below doesn't double-end the same identifier.
                    if taskId != .invalid {
                        app.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                }
            }

            defer {
                if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication, taskId != .invalid {
                    app.endBackgroundTask(taskId)
                    taskId = .invalid
                }
            }

            for _ in 1...3 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let account = vehicle.account else { break }
                try? await account.fetchAndUpdateVehicleStatus(for: vehicle, modelContext: modelContext)

                if (type == .climate && vehicle.climateStatus?.airControlOn == true) ||
                    (type == .charging && vehicle.evStatus?.charging == true) {
                    break
                }
            }

            // If state didn't change, end the activity after a delay
            if (type == .climate && vehicle.climateStatus?.airControlOn != true) ||
                (type == .charging && vehicle.evStatus?.charging != true) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                endActivity(for: vehicle)
            }
        }
        #endif
    }

    private func createStatusFromVehicle(_ vehicle: BBVehicle) -> VehicleStatus? {
        guard let location = vehicle.location,
              let lock = vehicle.lockStatus,
              let climate = vehicle.climateStatus else { return nil }

        return VehicleStatus(
            vin: vehicle.vin,
            gasRange: vehicle.gasRange,
            evStatus: vehicle.evStatus,
            location: location,
            lockStatus: lock,
            climateStatus: climate,
            odometer: vehicle.odometer,
            syncDate: vehicle.syncDate
        )
    }

    /// Whether the app is in the foreground, where it can start cards
    /// itself. False in extensions, which have no shared application.
    private static var isAppActive: Bool {
        #if canImport(ActivityKit)
        (UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication)?.applicationState == .active
        #else
        false
        #endif
    }

    /// When the backend should start waking us for this status: the
    /// expected charge start for a car waiting on its schedule (no point
    /// polling a car that won't change for hours), now otherwise.
    nonisolated static func wakeupStart(for status: VehicleStatus, now: Date = Date()) -> Date? {
        guard let ev = status.evStatus, ev.isWaitingForScheduledCharge else { return nil }
        return ev.expectedChargeStart(after: now)
    }

    private func startOrUpdateActivity(
        for vehicle: BBVehicle,
        status: VehicleStatus,
        type: LiveActivityType,
        climatePresetName: String? = nil,
        climatePresetIcon: String? = nil
    ) {
        #if canImport(ActivityKit)
        var existingActivity = Self.activity(forVIN: vehicle.vin, vehicleId: vehicle.id)

        // A long-running waiting card whose car has started charging gets
        // replaced. In the foreground the app starts the new card itself.
        // In the background it can't, and this runs as a side effect of
        // the status fetch, before the wakeup handler has looked at the
        // card: leave the card alone so the handler can replace it by push.
        if let activity = existingActivity, type == .charging,
           Self.shouldReplace(state: activity.content.state, with: status) {
            guard Self.isAppActive else { return }
            nonisolated(unsafe) let old = activity
            Task { await old.end(nil, dismissalPolicy: .immediate) }
            existingActivity = nil
        }

        if let activity = existingActivity {
            let currentState = activity.content.state
            let wasWaiting = currentState.status.evStatus?.isWaitingForScheduledCharge == true
            var contentState = currentState
            contentState.status = status
            contentState.activityType = type
            contentState.climatePresetName = climatePresetName ?? currentState.climatePresetName
            contentState.climatePresetIcon = climatePresetIcon ?? currentState.climatePresetIcon
            contentState.vehicleName = vehicle.displayName
            contentState.chargingColorName = vehicle.chargingColorName
            nonisolated(unsafe) let activity = activity
            Task { @MainActor in
                await activity.update(ActivityContent(state: contentState, staleDate: Self.staleDate(for: status)))
            }
            // Waiting holds the wakeups until the charge is due; charging
            // wants them now. Re-register when that flips.
            let isWaiting = status.evStatus?.isWaitingForScheduledCharge == true
            if type == .charging, wasWaiting != isWaiting {
                Task { await registerWithBackend(activityType: .charging, startAt: Self.wakeupStart(for: status)) }
            }
        } else {
            let contentState = VehicleActivityAttributes.ContentState(
                status: status,
                activityType: type,
                climatePresetName: climatePresetName,
                climatePresetIcon: climatePresetIcon,
                vehicleName: vehicle.displayName,
                chargingColorName: vehicle.chargingColorName,
                startedAt: Date()
            )
            let attributes = VehicleActivityAttributes(
                vehicleName: vehicle.displayName,
                vin: vehicle.vin,
                vehicleId: vehicle.id,
                startClimateColorName: vehicle.startClimateColorName,
                chargingColorName: vehicle.chargingColorName
            )
            do {
                _ = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: Self.staleDate(for: status)),
                    pushType: nil // Updates come from the app itself, woken by the backend
                )
                // Register with backend for wakeup pushes with the activity type
                Task {
                    await registerWithBackend(activityType: type, startAt: Self.wakeupStart(for: status))
                }
            } catch {
                AppLogger.liveActivity.error("Error requesting activity: \(error)")
            }
        }
        #endif
    }

    // MARK: - Backend

    private func postToBackend(_ path: String, body: [String: Any]) async throws -> Int {
        guard let url = URL(string: "\(liveActivityBackendURL)/\(path)") else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func registerWithBackend(activityType: LiveActivityType = .charging, startAt: Date? = nil) async {
        guard let deviceToken = deviceToken else {
            AppLogger.liveActivity.warning("No device token available for backend registration")
            return
        }

        // Only charging and debug get backend wakeup pushes. Climate
        // activities are short-lived and driven by the foregrounded
        // app's polling — registering them just stuffs the wakeup
        // table with rows that don't need long-term refresh. The
        // backend now rejects them with 400 too.
        guard activityType == .charging || activityType == .debug else {
            AppLogger.liveActivity.info(
                "Skipping backend registration for short-lived activity type: \(activityType.rawValue, privacy: .public)"
            )
            return
        }

        var body: [String: Any] = [
            "pushToken": deviceToken,
            "activityType": activityType.rawValue  // "charging" or "debug"
        ]
        if let startAt, startAt > Date() {
            // Milliseconds, like the backend's own timestamps.
            body["startAt"] = Int(startAt.timeIntervalSince1970 * 1000)
        }

        do {
            let statusCode = try await postToBackend("wakeup", body: body)
            if statusCode == 200 {
                isRegisteredWithBackend = true
                AppLogger.liveActivity.info("Registered with backend for wakeup pushes (type: \(activityType.rawValue, privacy: .public))")
            } else {
                AppLogger.liveActivity.error("Backend registration failed: \(statusCode)")
            }
        } catch {
            AppLogger.liveActivity.error("Backend registration error: \(error)")
        }
    }

    private func unregisterFromBackend() async {
        guard let deviceToken = deviceToken else { return }
        do {
            _ = try await postToBackend("wakeup/unregister", body: ["pushToken": deviceToken])
            isRegisteredWithBackend = false
            AppLogger.liveActivity.info("Unregistered from backend")
        } catch {
            AppLogger.liveActivity.error("Backend unregistration error: \(error)")
        }
    }

    private func endActivity(for vehicle: BBVehicle) {
        #if canImport(ActivityKit)
        guard let existingActivity = Self.activity(forVIN: vehicle.vin, vehicleId: vehicle.id) else {
            return
        }

        nonisolated(unsafe) let activity = existingActivity
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)

            // If no more active Live Activities, unregister from backend
            if Activity<VehicleActivityAttributes>.activities.count <= 1 {
                await unregisterFromBackend()
            }
        }
        #endif
    }

    // MARK: - Push-to-start

    private static let pushToStartTokenKey = "LiveActivityPushToStartToken"

    /// The token the backend uses to start a card on this phone with a
    /// push. iOS hands it out once the app has asked for it and may
    /// rotate it; the latest is kept so a background wakeup can use it.
    private(set) var pushToStartToken: String? = UserDefaults.standard.string(forKey: LiveActivityManager.pushToStartTokenKey)

    /// Starts listening for push-to-start tokens. Call at launch.
    func startObservingPushToStartTokens() {
        #if canImport(ActivityKit)
        guard !isObservingPushToStartTokens else { return }
        isObservingPushToStartTokens = true
        Task {
            for await data in Activity<VehicleActivityAttributes>.pushToStartTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard token != pushToStartToken else { continue }
                pushToStartToken = token
                UserDefaults.standard.set(token, forKey: Self.pushToStartTokenKey)
                AppLogger.liveActivity.info("Push-to-start token: \(token.prefix(12), privacy: .public)...")
            }
        }
        #endif
    }

    #if canImport(ActivityKit)
    /// A stand-in status for a card the backend starts: no VIN, no
    /// readings. It is all the backend ever sees, and the app replaces
    /// it with the real status as soon as the card appears.
    private static var placeholderStatus: VehicleStatus {
        VehicleStatus(
            vin: "",
            evStatus: VehicleStatus.EVStatus(
                charging: true,
                chargeSpeed: 0,
                evRange: .init(range: Distance(length: 0, units: .miles), percentage: 0),
                chargeTime: .seconds(0)
            ),
            location: .init(latitude: 0, longitude: 0),
            lockStatus: .unknown,
            climateStatus: .init(
                defrostOn: false,
                airControlOn: false,
                steeringWheelHeatingOn: false,
                temperature: Temperature(value: 72, units: .fahrenheit)
            )
        )
    }

    /// Asks the backend to start a charging card with a push — the only
    /// way to start one while the app is in the background — then fills
    /// it in with `status` once it appears. What goes to the backend
    /// identifies nothing: an empty name and VIN, the stand-in status, and
    /// the vehicle's app-local id so the card can be matched up again.
    /// Returns nil if there's no token or no card turns up in time.
    private func startActivityByPush(
        for vehicle: VehicleSnapshot,
        status: VehicleStatus,
        excluding excludedId: String? = nil
    ) async -> Activity<VehicleActivityAttributes>? {
        guard let token = pushToStartToken else {
            AppLogger.liveActivity.warning("No push-to-start token; can't start a Live Activity from the background")
            return nil
        }

        let attributes = VehicleActivityAttributes(vehicleName: "", vin: "", vehicleId: vehicle.id)
        let placeholder = VehicleActivityAttributes.ContentState(
            status: Self.placeholderStatus,
            activityType: .charging,
            activityState: .starting
        )
        do {
            let encoder = JSONEncoder()
            guard let attributesJSON = try JSONSerialization.jsonObject(with: encoder.encode(attributes)) as? [String: Any],
                  let stateJSON = try JSONSerialization.jsonObject(with: encoder.encode(placeholder)) as? [String: Any] else {
                return nil
            }
            let body: [String: Any] = [
                "pushToStartToken": token,
                "attributes": attributesJSON,
                "contentState": stateJSON,
                "staleDate": Int(Date().addingTimeInterval(10 * 60).timeIntervalSince1970),
                "alert": ["title": "Charging Started", "body": "Your vehicle is charging."]
            ]
            let statusCode = try await postToBackend("liveactivity/start", body: body)
            guard statusCode == 200 else {
                AppLogger.liveActivity.error("Push-to-start request failed: \(statusCode)")
                return nil
            }
        } catch {
            AppLogger.liveActivity.error("Push-to-start request error: \(error)")
            return nil
        }

        guard let activity = await Self.awaitNewActivity(vehicleId: vehicle.id, excluding: excludedId, timeout: 8) else {
            AppLogger.liveActivity.warning("Push-started Live Activity didn't appear in time")
            return nil
        }

        var state = placeholder
        state.status = status
        state.activityState = .running
        state.vehicleName = vehicle.displayName
        state.chargingColorName = vehicle.chargingColorName
        state.startedAt = Date()
        nonisolated(unsafe) let started = activity
        await started.update(ActivityContent(state: state, staleDate: Self.staleDate(for: status)))
        return activity
    }

    /// The first card for `vehicleId` other than `excludedId`, waiting up
    /// to `timeout` seconds for the push to land.
    private nonisolated static func awaitNewActivity(
        vehicleId: UUID,
        excluding excludedId: String?,
        timeout: TimeInterval
    ) async -> Activity<VehicleActivityAttributes>? {
        if let existing = Activity<VehicleActivityAttributes>.activities.first(where: {
            isPushStarted($0, vehicleId: vehicleId, excluding: excludedId)
        }) {
            return existing
        }
        let foundId: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await activity in Activity<VehicleActivityAttributes>.activityUpdates
                    where isPushStarted(activity, vehicleId: vehicleId, excluding: excludedId) {
                    return activity.id
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return Activity<VehicleActivityAttributes>.activities.first { activity in
            if let foundId { return activity.id == foundId }
            return isPushStarted(activity, vehicleId: vehicleId, excluding: excludedId)
        }
    }

    private nonisolated static func isPushStarted(
        _ activity: Activity<VehicleActivityAttributes>,
        vehicleId: UUID,
        excluding excludedId: String?
    ) -> Bool {
        activity.attributes.vehicleId == vehicleId && activity.attributes.vin.isEmpty && activity.id != excludedId
    }
    #endif

    // MARK: - Nightly charge check

    /// What the backend holds for the nightly check.
    private struct NightlyRegistration: Codable, Equatable {
        let pushToken: String
        /// Local "HH:mm".
        let time: String
        let timeZone: String
    }

    private static let lastNightlyRegistrationKey = "LastNightlyRegistration"

    /// The check time 5 minutes after the first EV's off-peak start, with
    /// that vehicle's name, or nil when no EV reports an off-peak window.
    static func defaultNightlyCheckTime(for vehicles: [BBVehicle]) -> (time: TimeOfDay, vehicleName: String, offPeakStart: TimeOfDay)? {
        let first = vehicles
            .filter { $0.fuelType.hasElectricCapability }
            .sorted { $0.sortOrder < $1.sortOrder }
            .first { $0.evStatus?.chargingSchedule?.offPeakEnabled == true }
        guard let first, let start = first.evStatus?.chargingSchedule?.offPeakWindow.start else { return nil }
        return (start.adding(minutes: 5), first.displayName, start)
    }

    /// The time the nightly check runs: the user's own, else 5 minutes
    /// after the first EV's off-peak start, else 12:05 AM.
    static func nightlyCheckTime(for vehicles: [BBVehicle]) -> TimeOfDay {
        if let minutes = AppSettings.shared.nightlyChargeCheckMinutes {
            return TimeOfDay(minutesSinceMidnight: minutes)
        }
        return defaultNightlyCheckTime(for: vehicles)?.time ?? TimeOfDay(hour: 0, minute: 5)
    }

    /// Brings the backend's nightly check in line with the settings:
    /// registers (or re-times) it when on, removes it when off. Sends
    /// nothing when the backend already has the same thing.
    func syncNightlyCheck() async {
        guard let deviceToken else { return }
        let defaults = UserDefaults.standard
        let lastSent = defaults.data(forKey: Self.lastNightlyRegistrationKey)
            .flatMap { try? JSONDecoder().decode(NightlyRegistration.self, from: $0) }
        let settings = AppSettings.shared

        guard settings.liveActivitiesEnabled, settings.nightlyChargeCheckEnabled else {
            guard lastSent != nil else { return }
            do {
                _ = try await postToBackend("nightly/unregister", body: ["pushToken": deviceToken])
                defaults.removeObject(forKey: Self.lastNightlyRegistrationKey)
                AppLogger.liveActivity.info("Nightly charge check off")
            } catch {
                AppLogger.liveActivity.error("Nightly unregister error: \(error)")
            }
            return
        }

        let vehicles = (try? appModelContainer?.mainContext.fetch(FetchDescriptor<BBVehicle>())) ?? []
        let time = Self.nightlyCheckTime(for: vehicles)
        let registration = NightlyRegistration(
            pushToken: deviceToken,
            time: String(format: "%02d:%02d", time.hour, time.minute),
            timeZone: TimeZone.current.identifier
        )
        guard registration != lastSent else { return }

        let body: [String: Any] = [
            "pushToken": registration.pushToken,
            "time": registration.time,
            "timeZone": registration.timeZone
        ]
        do {
            let statusCode = try await postToBackend("nightly", body: body)
            guard statusCode == 200 else {
                AppLogger.liveActivity.error("Nightly registration failed: \(statusCode)")
                return
            }
            defaults.set(try JSONEncoder().encode(registration), forKey: Self.lastNightlyRegistrationKey)
            AppLogger.liveActivity.info("Nightly charge check at \(registration.time, privacy: .public) \(registration.timeZone, privacy: .public)")
        } catch {
            AppLogger.liveActivity.error("Nightly registration error: \(error)")
        }
    }

    /// The nightly push: for each EV, see whether it's charging and, if
    /// it is and has no card, have the backend start one. Then tell the
    /// backend whether to try again in 10 minutes (a car still waiting on
    /// its schedule) or call it a night.
    func handleNightlyCheckPush() async {
        AppLogger.liveActivity.info("Handling nightly charge check...")
        #if canImport(ActivityKit)
        let settings = AppSettings.shared
        guard settings.liveActivitiesEnabled, settings.nightlyChargeCheckEnabled,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let container = Self.backgroundContainer() else {
            await acknowledgeNightlyCheck(outcome: "disabled")
            return
        }

        let targets: [(vin: String, id: UUID)] = {
            let context = ModelContext(container)
            let vehicles = (try? context.fetch(FetchDescriptor<BBVehicle>())) ?? []
            return vehicles
                .filter { $0.fuelType.hasElectricCapability && $0.account != nil }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { ($0.vin, $0.id) }
        }()

        var anyCharging = false
        var anyWaiting = false
        for target in targets {
            do {
                guard let fetched = try await updateVehicleStatus(
                    vin: target.vin, vehicleId: target.id, container: container
                ) else { continue }
                var (status, vehicle) = fetched

                // The cached status may predate the charge starting (the
                // car doesn't always report it). If it still says waiting
                // and is older than the expected start, ask the car itself.
                if let ev = status.evStatus, ev.isWaitingForScheduledCharge,
                   let start = ev.expectedChargeStart(after: (status.syncDate ?? status.lastUpdated).addingTimeInterval(-60)),
                   (status.syncDate ?? status.lastUpdated) < start, start <= Date(),
                   let live = try await updateVehicleStatus(
                       vin: target.vin, vehicleId: target.id, container: container, cached: false
                   ) {
                    (status, vehicle) = live
                }

                guard let ev = status.evStatus else { continue }
                if ev.charging {
                    anyCharging = true
                    if Self.activity(forVIN: vehicle.vin, vehicleId: vehicle.id) != nil {
                        await refreshOrRetireActivity(for: vehicle, status: status)
                    } else {
                        _ = await startActivityByPush(for: vehicle, status: status)
                    }
                } else if ev.isWaitingForScheduledCharge {
                    anyWaiting = true
                }
            } catch {
                AppLogger.liveActivity.error("Nightly check failed for \(target.vin.prefix(8), privacy: .public): \(error)")
                anyWaiting = true // try again on the next attempt
            }
        }

        if anyCharging {
            await registerWithBackend(activityType: .charging)
        }
        // Still waiting: let the backend's next attempt look again.
        if anyCharging || !anyWaiting {
            await acknowledgeNightlyCheck(outcome: anyCharging ? "charging" : "notCharging")
        }
        #endif
    }

    private func acknowledgeNightlyCheck(outcome: String) async {
        guard let deviceToken else { return }
        do {
            _ = try await postToBackend("nightly/ack", body: ["pushToken": deviceToken, "outcome": outcome])
        } catch {
            AppLogger.liveActivity.error("Nightly ack error: \(error)")
        }
    }
}

// MARK: - Types

public enum LiveActivityState: String, Codable, Hashable, Sendable {
    case starting, running, failed
}

public enum LiveActivityType: String, Codable, Hashable, Sendable {
    case climate, charging, debug, none

    public func message(for state: LiveActivityState) -> String {
        switch (self, state) {
        case (.climate, .starting): return "Starting Climate..."
        case (.climate, .running): return "Climate Active"
        case (.climate, .failed): return "Climate Failed"
        case (.charging, .starting): return "Starting Charge..."
        case (.charging, .running): return "Charging"
        case (.charging, .failed): return "Charge Failed"
        case (.debug, .starting): return "Debug Starting..."
        case (.debug, .running): return "Debug Active"
        case (.debug, .failed): return "Debug Failed"
        case (.none, .starting): return "Updating..."
        case (.none, .running): return "Updated"
        case (.none, .failed): return "Update Failed"
        }
    }

    public var refreshIntervalMinutes: Int {
        return 1
    }
}

// MARK: - Activity Attributes

#if canImport(ActivityKit)
public struct VehicleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: VehicleStatus
        public var activityType: LiveActivityType
        public var activityState: LiveActivityState
        public var isRefreshing: Bool
        public var climatePresetName: String?
        public var climatePresetIcon: String?
        // Debug fields
        public var wakeupCount: Int
        public var lastWakeupTime: Date?
        /// The vehicle's name and charging color, carried here as well as
        /// in the attributes because a card the backend starts has empty
        /// attributes (nothing identifying goes through it) and attributes
        /// can't change afterwards. The card prefers these.
        public var vehicleName: String?
        public var chargingColorName: String?
        /// When the card started, for replacing a long-running waiting
        /// card before ActivityKit's 8-hour limit ends it mid-charge.
        public var startedAt: Date?

        public init(
            status: VehicleStatus,
            activityType: LiveActivityType = .none,
            activityState: LiveActivityState = .running,
            isRefreshing: Bool = false,
            climatePresetName: String? = nil,
            climatePresetIcon: String? = nil,
            wakeupCount: Int = 0,
            lastWakeupTime: Date? = nil,
            vehicleName: String? = nil,
            chargingColorName: String? = nil,
            startedAt: Date? = nil
        ) {
            self.status = status
            self.activityType = activityType
            self.activityState = activityState
            self.isRefreshing = isRefreshing
            self.climatePresetName = climatePresetName
            self.climatePresetIcon = climatePresetIcon
            self.wakeupCount = wakeupCount
            self.lastWakeupTime = lastWakeupTime
            self.vehicleName = vehicleName
            self.chargingColorName = chargingColorName
            self.startedAt = startedAt
        }
    }

    public var vehicleName: String
    public var vin: String
    public var vehicleId: UUID
    /// Per-vehicle accent colors. Captured at activity-start time so the
    /// Live Activity can render in the user's chosen palette without doing
    /// SwiftData lookups in the widget process. Already-running activities
    /// won't reflect changes until the activity is restarted.
    public var startClimateColorName: String?
    public var chargingColorName: String?

    public init(
        vehicleName: String,
        vin: String,
        vehicleId: UUID,
        startClimateColorName: String? = nil,
        chargingColorName: String? = nil
    ) {
        self.vehicleName = vehicleName
        self.vin = vin
        self.vehicleId = vehicleId
        self.startClimateColorName = startClimateColorName
        self.chargingColorName = chargingColorName
    }
}
#endif
