//
//  Vehicle.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/6/25.
//

import BetterBlueKit
import Foundation
import SwiftData
import SwiftUI

/// User preference for charge port type (affects DC plug icon display)
enum ChargePortType: String, Codable, CaseIterable {
    case ccs1 = "CCS1"
    case ccs2 = "CCS2"
    case nacs = "NACS"

    var displayName: String {
        rawValue
    }

    var dcPlugIcon: String {
        switch self {
        case .ccs1: return "ev.plug.dc.ccs1"
        case .ccs2: return "ev.plug.dc.ccs2"
        case .nacs: return "ev.plug.dc.nacs"
        }
    }

    var acPlugIcon: String {
        switch self {
        case .ccs1: return "ev.plug.ac.type.1"
        case .ccs2: return "ev.plug.ac.type.2"
        case .nacs: return "ev.plug.dc.nacs"
        }
    }
}

@Model
class BBVehicle {
    var id: UUID = UUID()
    var vin: String = ""

    // Vehicle fields (all required)
    var regId: String = ""
    var model: String = ""
    var accountId: UUID = UUID()
    var fuelTypeRaw: String = FuelType.gas.rawValue
    var generation: Int = 0
    var odometer: Distance = Distance(length: 0, units: .miles)

    // VehicleStatus fields (all optional since status might not be fetched)
    var lastUpdated: Date?
    var syncDate: Date?
    var gasRange: VehicleStatus.FuelRange?
    var evStatus: VehicleStatus.EVStatus?
    var location: VehicleStatus.Location?
    var lockStatus: VehicleStatus.LockStatus?
    var climateStatus: VehicleStatus.ClimateStatus?

    // Additional status fields
    var battery12V: Int?
    var doorOpen: VehicleStatus.DoorStatus?
    var trunkOpen: Bool?
    var hoodOpen: Bool?
    var tirePressureWarning: VehicleStatus.TirePressureWarning?

    // Custom name and visibility (kept separate for easier queries)
    var customName: String?
    var isHidden: Bool = false
    var sortOrder: Int = 0
    var backgroundColorName: String = "default"
    var watchBackgroundColorName: String = "charcoal"
    var chargePortTypeRaw: String = ChargePortType.ccs1.rawValue
    var debugConfiguration: BBDebugConfiguration?
    var debugLiveActivity: Bool = false

    /// Override to show seat heat controls on older vehicles (generation < 3)
    /// Ignored for generation 3+ vehicles where seat heat controls are always shown
    var enableSeatHeatControls: Bool = false

    /// Per-vehicle toggle for the climate duration picker. `nil` = use
    /// the regional default (non-USA shows the picker, USA hides it
    /// because the API ignores the duration field there); `true`/
    /// `false` pin the visibility regardless of region. Lives next to
    /// `enableSeatHeatControls` because both are "I know my car better
    /// than the heuristic" overrides.
    var showClimateDurationOverride: Bool?

    // MARK: - Per-vehicle accent colors
    //
    // All five default to `nil` so old SwiftData rows decode without a
    // migration; the resolver in `CustomColors.color(forName:default:)`
    // returns a sensible default whenever the stored name is missing.
    // Stored as String (palette name) instead of Color because SwiftUI
    // `Color` isn't natively persistable.

    /// Refresh button + map pin tint. Default: blue.
    var primaryColorName: String?
    /// Charging bolt + "Stop Charge" button color. Default: green.
    var chargingColorName: String?
    /// Color shown when the vehicle is locked (status icon + tap-to-lock
    /// quick action). Default: red.
    var lockColorName: String?
    /// Color shown when the vehicle is unlocked (status icon +
    /// tap-to-unlock quick action). Default: green.
    var unlockColorName: String?
    /// Climate quick-action button + "Stop Climate" status color.
    /// Default: blue.
    var startClimateColorName: String?

    // MARK: - Fuel-type override
    //
    // The Kia/Hyundai vehicle-list endpoints don't always return a
    // reliable powertrain marker (Kia USA in particular only confirms
    // `fuelType == 4` as EV; everything else falls into `.gas`). The
    // self-heal in `updateStatus` infers the real type from the status
    // payload's shape, but the API can still mis-shape its own response
    // — e.g. issue #41 has a real EV that returns both an `evStatus`
    // and a phantom `gasRange` (length matching the EV range), which
    // promotes the vehicle to PHEV and won't demote even after
    // re-adding the account.
    //
    // This stored override lets the user pin the powertrain manually.
    // `nil` = trust the inferred value (default behaviour).
    var fuelTypeOverrideRaw: String?

    var chargePortType: ChargePortType {
        get { ChargePortType(rawValue: chargePortTypeRaw) ?? .ccs1 }
        set { chargePortTypeRaw = newValue.rawValue }
    }

    /// User override for the inferred powertrain. `nil` means "use
    /// whatever the API/self-heal decided". Setting it to a non-nil
    /// value pins `fuelType` to that choice; clearing it (set to nil)
    /// returns control to the inferred value.
    var fuelTypeOverride: FuelType? {
        get {
            guard let raw = fuelTypeOverrideRaw else { return nil }
            return FuelType(rawValue: raw)
        }
        set { fuelTypeOverrideRaw = newValue?.rawValue }
    }

    /// Effective "show climate duration picker" decision. Reads the
    /// override when pinned, otherwise infers from generation + region:
    /// generation-3+ vehicles honor the duration field globally, and
    /// non-USA vehicles of any generation also honor it. Pre-gen-3 USA
    /// vehicles default off because the API ignores duration there.
    /// Account is optional because newly-created vehicles may not be
    /// wired up yet; treat the absent case as "show" to match the more
    /// common default outside the USA.
    var showClimateDuration: Bool {
        if let override = showClimateDurationOverride { return override }
        if generation >= 3 { return true }
        return account?.regionEnum != .usa
    }

    /// Powertrain that the rest of the app should use. Reads the
    /// override when the user has pinned one, otherwise falls back to
    /// the self-healed `fuelTypeRaw`. The setter still writes to
    /// `fuelTypeRaw` so the inferred value continues to track API
    /// hints — clearing the override later just reveals whatever the
    /// inference has converged on.
    var fuelType: FuelType {
        get {
            if let override = fuelTypeOverride { return override }
            return FuelType(rawValue: fuelTypeRaw) ?? .gas
        }
        set { fuelTypeRaw = newValue.rawValue }
    }

    // Optional vehicle key for Kia vehicles
    @Transient var vehicleKey: String?

    @Relationship(inverse: \BBAccount.vehicles) var account: BBAccount?
    @Relationship(deleteRule: .cascade) var climatePresets: [ClimatePreset]? = []

    var safeClimatePresets: [ClimatePreset] {
        climatePresets ?? []
    }

    init(from vehicle: Vehicle, backgroundColorName: String? = nil) {
        id = UUID()
        vin = vehicle.vin
        regId = vehicle.regId
        model = vehicle.model
        accountId = vehicle.accountId
        fuelType = vehicle.fuelType
        generation = vehicle.generation
        odometer = vehicle.odometer

        // Initialize status fields as nil
        lastUpdated = nil
        syncDate = nil
        gasRange = nil
        evStatus = nil
        location = nil
        lockStatus = nil
        climateStatus = nil
        battery12V = nil
        doorOpen = nil
        trunkOpen = nil
        hoodOpen = nil
        tirePressureWarning = nil

        customName = nil
        isHidden = false
        vehicleKey = vehicle.vehicleKey
        if let color = backgroundColorName {
            self.backgroundColorName = color
        }
    }
}

// MARK: - Status Management

extension BBVehicle {
    /// Apply the off-axis-range cleanup that follows from a fuel-type
    /// override change. Call after the user picks a new override (or
    /// clears it). `updateStatus` already gates writes on the effective
    /// `fuelType`, but stale `gasRange`/`evStatus` set BEFORE the
    /// override was applied won't go away on their own — this method
    /// nukes the irrelevant fields up-front so the UI updates without
    /// waiting for the next status fetch.
    @MainActor
    func normalizeRangesForCurrentFuelType() {
        switch fuelType {
        case .gas:
            evStatus = nil
        case .electric:
            gasRange = nil
        case .phev:
            // PHEV legitimately keeps both — nothing to clear.
            break
        }
    }

    /// Returns true when `to` is more specific than `from` along the
    /// `gas → electric → phev` axis. Used by `updateStatus` to one-way
    /// upgrade a misclassified `fuelType` once a status payload reveals
    /// the real powertrain — without ever demoting (e.g. a PHEV momentarily
    /// returning evStatus only shouldn't flip back to electric).
    fileprivate func isFuelTypeUpgrade(from: FuelType, to: FuelType) -> Bool {
        switch (from, to) {
        case (.gas, .electric), (.gas, .phev), (.electric, .phev):
            return true
        default:
            return false
        }
    }

    @MainActor
    func updateStatus(with status: VehicleStatus) {
        // Wake up any waiting status change tasks (cancel them so they can restart immediately)
        wakeUpStatusWaiters()

        // Update all fields with the merged status
        lastUpdated = status.lastUpdated
        syncDate = status.syncDate

        // ----- Self-heal `fuelType` from status payload shape -----
        //
        // Borrowed from `hyundai_kia_connect_api`'s `KiaUvoApiUSA`
        // `_update_vehicle_properties`: when the vehicles-list parser
        // can't authoritatively classify the powertrain (Kia USA only
        // confirms `fuelType == 4` as EV; everything else falls into
        // `.gas` as a conservative default), the status response's
        // structure is the source of truth.
        //
        //   - `evStatus` present                ⇒ has a high-voltage battery
        //   - `evStatus` + `gasRange` present   ⇒ PHEV
        //   - `evStatus` only                   ⇒ pure EV
        //   - `gasRange` only                   ⇒ pure ICE
        //
        // We only ever UPGRADE specificity (gas → electric → phev) so
        // a one-off missing field in a status response can't demote a
        // vehicle we already know is a PHEV back to electric or gas.
        let inferredType: FuelType?
        switch (status.evStatus, status.gasRange) {
        case (.some, .some): inferredType = .phev
        case (.some, .none): inferredType = .electric
        case (.none, .some): inferredType = .gas
        case (.none, .none): inferredType = nil
        }
        if let inferredType, isFuelTypeUpgrade(from: fuelType, to: inferredType) {
            BBLogger.info(
                .api,
                "BBVehicle: self-heal fuelType \(fuelType.rawValue) → \(inferredType.rawValue) for VIN \(vin) based on status payload shape"
            )
            fuelType = inferredType
        }

        // Update gas range and EV status, keeping existing values if new ones aren't provided.
        // PHEVs can have both gasRange and evStatus simultaneously.
        if [.gas, .phev].contains(fuelType), let gasRange = status.gasRange {
            self.gasRange = gasRange
        }
        if [.electric, .phev].contains(fuelType), let evStatus = status.evStatus {
            self.evStatus = evStatus
        }
        // Only clear gas range for pure EVs (PHEVs retain both gas and EV range)
        if fuelType == .electric && status.evStatus != nil && status.gasRange == nil {
            self.gasRange = nil
        }
        if fuelType == .gas && status.evStatus == nil && status.gasRange != nil {
            self.evStatus = nil
        }
        
        location = status.location
        lockStatus = status.lockStatus
        climateStatus = status.climateStatus
        if let odometer = status.odometer {
            self.odometer = odometer
        }

        // Update additional status fields
        battery12V = status.battery12V
        doorOpen = status.doorOpen
        trunkOpen = status.trunkOpen
        hoodOpen = status.hoodOpen
        tirePressureWarning = status.tirePressureWarning
    }

    // MARK: - Status Change Waiting

    // Simple actor to manage wake-up continuations
    private actor StatusWaitingManager {
        private var wakeUpContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

        func setWakeUpContinuation(
            for vehicleId: UUID,
            continuation: CheckedContinuation<Void, Never>,
        ) {
            wakeUpContinuations[vehicleId] = continuation
        }

        func wakeUp(vehicleId: UUID) -> Bool {
            if let continuation = wakeUpContinuations.removeValue(forKey: vehicleId) {
                continuation.resume()
                return true
            }
            return false
        }

        func clearWakeUp(for vehicleId: UUID) {
            if let continuation = wakeUpContinuations.removeValue(forKey: vehicleId) {
                // Resume the continuation to prevent leak
                continuation.resume()
            }
        }
    }

    private static let statusWaitingManager = StatusWaitingManager()

    @MainActor
    func waitForStatusChange(
        modelContext: ModelContext,
        condition: @escaping @Sendable (VehicleStatus) -> Bool,
        statusMessageUpdater: (@Sendable (String) -> Void)? = nil,
        maxAttempts: Int = 3,
        initialDelaySeconds: Int = 10,
        retryDelaySeconds: Int = 10,
    ) async throws {
        // Initial delay to allow command to process
        statusMessageUpdater?("Command sent")
        try await interruptibleSleep(seconds: initialDelaySeconds)

        var currentAttempt = 0

        while currentAttempt < maxAttempts {
            try Task.checkCancellation()

            guard let account else {
                throw APIError(message: "Account not found for vehicle")
            }

            // Post-command verification needs to reflect the vehicle's
            // actual state, not the backend's cached snapshot.
            let updatedStatus = try await account.fetchVehicleStatus(
                for: self,
                modelContext: modelContext,
                cached: false
            )

            // Update the vehicle's status
            updateStatus(with: updatedStatus)

            if condition(updatedStatus) {
                print(
                    "✅ [BBVehicle] Status condition met for vehicle \(displayName)",
                )
                return
            }

            currentAttempt += 1
            if currentAttempt < maxAttempts {
                statusMessageUpdater?(
                    "Waiting for vehicle (\(currentAttempt)/\(maxAttempts))"
                )
                try await interruptibleSleep(seconds: retryDelaySeconds)
            }
        }

        throw APIError(
            message: "Status change condition not met after \(maxAttempts) attempts",
        )
    }

    @MainActor
    private func interruptibleSleep(seconds: Int) async throws {
        let vehicleId = id

        // Ensure any existing continuation is cleared before setting up a new one
        await Self.statusWaitingManager.clearWakeUp(for: vehicleId)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            // Add timer task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                return false // Timer completed normally
            }

            // Add wake-up task
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task {
                        await Self.statusWaitingManager.setWakeUpContinuation(
                            for: vehicleId,
                            continuation: continuation,
                        )
                    }
                }
                return true // Wake-up was triggered
            }

            // Wait for the first task to complete
            let wasWakeUp = try await group.next() ?? false

            // Cancel remaining tasks and ensure continuation cleanup
            group.cancelAll()
            await Self.statusWaitingManager.clearWakeUp(for: vehicleId)

            if wasWakeUp {
                print(
                    "⏰ [BBVehicle] Sleep interrupted by wake-up for vehicle \(self.displayName)",
                )
            }
        }
    }

    @MainActor
    func wakeUpStatusWaiters() {
        Task {
            let wasAwakened = await Self.statusWaitingManager.wakeUp(
                vehicleId: self.id,
            )
            if wasAwakened {
                print(
                    "🔔 [BBVehicle] Waking up status waiter for vehicle \(self.displayName)",
                )
            }
        }
    }

    @MainActor
    func clearPendingStatusWaiters() async {
        await Self.statusWaitingManager.clearWakeUp(for: id)
        print(
            "🧹 [BBVehicle] Cleared pending status waiters for vehicle \(displayName)",
        )
    }
}

// MARK: - UI and Display

extension BBVehicle {
    var displayName: String {
        customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ?
            customName! : model
    }

    // MARK: - Per-vehicle accent colors (resolved)

    /// Refresh button + map pin tint.
    var primaryColor: Color {
        CustomColor.color(forName: primaryColorName, default: "blue")
    }

    /// Bolt icon when initiating charge / "Stop Charge" button.
    var chargingColor: Color {
        CustomColor.color(forName: chargingColorName, default: "green")
    }

    /// Color shown when the vehicle is locked.
    var lockColor: Color {
        CustomColor.color(forName: lockColorName, default: "red")
    }

    /// Color shown when the vehicle is unlocked.
    var unlockColor: Color {
        CustomColor.color(forName: unlockColorName, default: "green")
    }

    /// Climate start action color.
    var startClimateColor: Color {
        CustomColor.color(forName: startClimateColorName, default: "blue")
    }

    /// Returns the appropriate plug icon based on current charging state and user's port type preference
    func plugIcon(for plugType: VehicleStatus.PlugType?) -> Image {
        guard let plugType else {
            return Image("custom.powerplug.portrait.slash")
        }

        switch plugType {
        case .unplugged:
            return Image("custom.powerplug.portrait.slash")
        case .acCharger:
            return Image(systemName: chargePortType.acPlugIcon)
        case .dcCharger:
            return Image(systemName: chargePortType.dcPlugIcon)
        }
    }
}

// MARK: - Codable Conformance for Export

extension BBVehicle: Encodable {
    enum CodingKeys: String, CodingKey {
        case id, vin, regId, model, accountId, fuelTypeRaw, generation, odometer
        case lastUpdated, syncDate, gasRange, evStatus, location, lockStatus, climateStatus
        case battery12V, doorOpen, trunkOpen, hoodOpen, tirePressureWarning
        case customName, isHidden, sortOrder, backgroundColorName, watchBackgroundColorName
        case chargePortTypeRaw, debugConfiguration, debugLiveActivity, enableSeatHeatControls
        case primaryColorName, chargingColorName, lockColorName, unlockColorName, startClimateColorName
        case fuelTypeOverrideRaw
        case showClimateDurationOverride
        case climatePresets
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Core vehicle fields
        try container.encode(id, forKey: .id)
        try container.encode(vin, forKey: .vin)
        try container.encode(regId, forKey: .regId)
        try container.encode(model, forKey: .model)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(fuelTypeRaw, forKey: .fuelTypeRaw)
        try container.encode(generation, forKey: .generation)
        try container.encode(odometer, forKey: .odometer)

        // Status fields
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(syncDate, forKey: .syncDate)
        try container.encodeIfPresent(gasRange, forKey: .gasRange)
        try container.encodeIfPresent(evStatus, forKey: .evStatus)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(lockStatus, forKey: .lockStatus)
        try container.encodeIfPresent(climateStatus, forKey: .climateStatus)
        try container.encodeIfPresent(battery12V, forKey: .battery12V)
        try container.encodeIfPresent(doorOpen, forKey: .doorOpen)
        try container.encodeIfPresent(trunkOpen, forKey: .trunkOpen)
        try container.encodeIfPresent(hoodOpen, forKey: .hoodOpen)
        try container.encodeIfPresent(tirePressureWarning, forKey: .tirePressureWarning)

        // UI/Settings fields
        try container.encodeIfPresent(customName, forKey: .customName)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(backgroundColorName, forKey: .backgroundColorName)
        try container.encode(watchBackgroundColorName, forKey: .watchBackgroundColorName)
        try container.encode(chargePortTypeRaw, forKey: .chargePortTypeRaw)
        try container.encodeIfPresent(debugConfiguration, forKey: .debugConfiguration)
        try container.encode(debugLiveActivity, forKey: .debugLiveActivity)
        try container.encode(enableSeatHeatControls, forKey: .enableSeatHeatControls)

        // Per-vehicle accent colors
        try container.encodeIfPresent(primaryColorName, forKey: .primaryColorName)
        try container.encodeIfPresent(chargingColorName, forKey: .chargingColorName)
        try container.encodeIfPresent(lockColorName, forKey: .lockColorName)
        try container.encodeIfPresent(unlockColorName, forKey: .unlockColorName)
        try container.encodeIfPresent(startClimateColorName, forKey: .startClimateColorName)

        // Fuel-type override (nil = inferred). Useful in debug exports
        // for diagnosing reports like #41 where the inferred type is
        // wrong and the user has pinned it manually.
        try container.encodeIfPresent(fuelTypeOverrideRaw, forKey: .fuelTypeOverrideRaw)
        try container.encodeIfPresent(showClimateDurationOverride, forKey: .showClimateDurationOverride)

        // Climate presets (relationship)
        try container.encode(safeClimatePresets, forKey: .climatePresets)
    }
}
