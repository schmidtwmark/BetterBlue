//
//  VehicleWidgetIntent.swift
//  BetterBlueWidget
//
//  Created by Mark Schmidt on 8/29/25.
//

import AppIntents
import BetterBlueKit
import SwiftData
import SwiftUI
import WidgetKit

struct VehicleWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource =
        "Vehicle Widget Configuration"
    static let description = IntentDescription("Choose a vehicle and buttons for the widget")

    @Parameter(
        title: "Vehicle",
        description: "Select which vehicle this widget controls",
    )
    var vehicle: VehicleEntity?

    /// Background override for this widget. "Default" follows the
    /// vehicle's configured background color.
    @Parameter(title: "Background")
    var background: WidgetBackgroundEntity?

    /// Append the numeric battery / fuel percentage after the range
    /// (e.g. "276 mi · 92%"), colored like the range. Default on, so
    /// widgets that predate these toggles keep showing the percentage.
    @Parameter(title: "Show EV Percentage", default: true)
    var showEVPercentage: Bool

    @Parameter(title: "Show Gas Percentage", default: true)
    var showGasPercentage: Bool

    // Configurable button slots. Optional so widgets configured before
    // these parameters existed keep working — `slotButtons` falls back
    // to the classic Lock/Unlock/Start/Stop set when nothing is set.
    // Each button has an optional color override; "Default" follows the
    // app's per-vehicle action color.
    @Parameter(title: "Button 1", optionsProvider: WidgetActionOptionsProvider(defaultKind: .lock))
    var action1: WidgetActionEntity?

    @Parameter(title: "Button 1 Color")
    var color1: WidgetColorEntity?

    @Parameter(title: "Button 2", optionsProvider: WidgetActionOptionsProvider(defaultKind: .unlock))
    var action2: WidgetActionEntity?

    @Parameter(title: "Button 2 Color")
    var color2: WidgetColorEntity?

    @Parameter(title: "Button 3", optionsProvider: WidgetActionOptionsProvider(defaultKind: .startClimate))
    var action3: WidgetActionEntity?

    @Parameter(title: "Button 3 Color")
    var color3: WidgetColorEntity?

    @Parameter(title: "Button 4", optionsProvider: WidgetActionOptionsProvider(defaultKind: .stopClimate))
    var action4: WidgetActionEntity?

    @Parameter(title: "Button 4 Color")
    var color4: WidgetColorEntity?

    init(vehicle: VehicleEntity?) {
        self.vehicle = vehicle
    }

    init() {
        action1 = .lock
        action2 = .unlock
        action3 = .startClimate
        action4 = .stopClimate
    }

    /// The buttons to render, in slot order: action plus optional color
    /// override. Empty ("None") slots are dropped — the remaining
    /// buttons re-flow into the grid. A widget with no slot configured
    /// at all (added before this feature, or never edited) gets the
    /// classic four buttons.
    var slotButtons: [ConfiguredWidgetButton] {
        let slots: [(WidgetActionEntity?, WidgetColorEntity?)] = [
            (action1, color1), (action2, color2), (action3, color3), (action4, color4)
        ]
        if slots.allSatisfy({ $0.0 == nil }) {
            return [.lock, .unlock, .startClimate, .stopClimate].map {
                ConfiguredWidgetButton(action: $0, colorName: nil)
            }
        }
        return slots.compactMap { action, color in
            guard let action, action.kind != .none else { return nil }
            return ConfiguredWidgetButton(action: action, colorName: color?.paletteName)
        }
    }

    /// The catalog name of the background to paint: the override's id
    /// when one is set, otherwise the vehicle's own (legacy) background
    /// name. The actual gradient + text color — including the adaptive
    /// "default" — is resolved view-side in `WidgetBackground`, which
    /// can use dynamic colors that swap with the system appearance.
    /// (The retired "vehicle-setting" id, if still stored on an old
    /// widget, falls through to the vehicle's background.)
    func effectiveBackgroundName(for vehicle: VehicleEntity) -> String {
        if let background, background.id != "vehicle-setting" {
            return background.id
        }
        return vehicle.backgroundColorName
    }
}

/// One rendered button: the action and the widget-local color override
/// (palette name; `nil` = use the app's per-vehicle color).
struct ConfiguredWidgetButton: Sendable {
    let action: WidgetActionEntity
    let colorName: String?

    func color(for vehicle: VehicleEntity) -> Color {
        if let colorName {
            return CustomColor.color(forName: colorName, default: "blue")
        }
        return action.kind.color(for: vehicle)
    }
}

// MARK: - Color / background override entities

/// A palette color choice for a button override. The "Default" entry
/// (id "default") means "no override — use the app's color".
struct WidgetColorEntity: AppEntity, Identifiable, Sendable {
    var id: String
    var displayName: String

    /// Palette name to feed `CustomColor`, or nil for the Default entry.
    var paletteName: String? { id == "default" ? nil : id }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color"
    static let defaultQuery = WidgetColorQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    static var appDefault: WidgetColorEntity {
        WidgetColorEntity(id: "default", displayName: "Default")
    }

    static var all: [WidgetColorEntity] {
        [.appDefault] + CustomColor.palette.map {
            WidgetColorEntity(id: $0.name, displayName: $0.displayName)
        }
    }
}

struct WidgetColorQuery: EntityQuery {
    func entities(for identifiers: [WidgetColorEntity.ID]) async throws -> [WidgetColorEntity] {
        identifiers.compactMap { id in WidgetColorEntity.all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [WidgetColorEntity] {
        WidgetColorEntity.all
    }

    func defaultResult() async -> WidgetColorEntity? {
        .appDefault
    }
}

/// A widget-background choice — the entries mirror the app's background
/// catalog. "Default" is the default and resolves adaptively (white in
/// light mode, dark glass in dark) view-side.
struct WidgetBackgroundEntity: AppEntity, Identifiable, Sendable {
    var id: String
    var displayName: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Background"
    static let defaultQuery = WidgetBackgroundQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    static var all: [WidgetBackgroundEntity] {
        BBVehicle.availableBackgrounds.map {
            WidgetBackgroundEntity(id: $0.name, displayName: $0.displayName)
        }
    }

    static var defaultBackground: WidgetBackgroundEntity? {
        all.first { $0.id == "default" }
    }
}

struct WidgetBackgroundQuery: EntityQuery {
    func entities(for identifiers: [WidgetBackgroundEntity.ID]) async throws -> [WidgetBackgroundEntity] {
        identifiers.compactMap { id in WidgetBackgroundEntity.all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [WidgetBackgroundEntity] {
        WidgetBackgroundEntity.all
    }

    func defaultResult() async -> WidgetBackgroundEntity? {
        .defaultBackground
    }
}

// MARK: - Configurable button actions

/// The command a single configurable button performs. `startClimate`
/// covers both the generic "selected preset" case (presetId == nil) and a
/// specific preset (presetId set) — see `WidgetActionEntity`.
enum WidgetActionKind: String, Sendable {
    case lock
    case unlock
    case startClimate
    case stopClimate
    case startCharge
    case stopCharge
    case none

    var defaultTitle: String {
        switch self {
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .startClimate: "Start Climate"
        case .stopClimate: "Stop Climate"
        case .startCharge: "Start Charge"
        case .stopCharge: "Stop Charge"
        case .none: "None"
        }
    }

    /// Icons match the original widget's button set (`fan`/`fan.slash`
    /// rather than the filled variants) so the design stays unchanged.
    var icon: String {
        switch self {
        case .lock: "lock.fill"
        case .unlock: "lock.open.fill"
        case .startClimate: "fan"
        case .stopClimate: "fan.slash"
        case .startCharge: "bolt.fill"
        case .stopCharge: "bolt.slash.fill"
        case .none: "circle.dashed"
        }
    }

    /// Resolves the per-vehicle custom color this action should use.
    func color(for vehicle: VehicleEntity) -> Color {
        switch self {
        case .lock: vehicle.lockColor
        case .unlock: vehicle.unlockColor
        case .startClimate: vehicle.startClimateColor
        case .stopClimate: vehicle.stopColor
        case .startCharge: vehicle.chargingColor
        case .stopCharge: vehicle.stopColor
        case .none: Color.gray
        }
    }
}

/// One selectable option in a button slot. Modeled as an `AppEntity`
/// (rather than a static `AppEnum`) so the picker can offer dynamic
/// options — specifically, one "Start Climate – <Preset>" entry per
/// climate preset the user has created.
struct WidgetActionEntity: AppEntity, Identifiable, Sendable {
    /// Stable identifier. Fixed actions use their kind raw value
    /// ("lock", "startClimate", …); preset-specific start-climate
    /// actions use "preset:<presetId>".
    var id: String
    var kindRaw: String
    var title: String
    var iconName: String

    // Populated only for a preset-specific start-climate action.
    var presetId: UUID?
    var presetVin: String?
    var presetVehicleName: String?
    var presetName: String?
    var presetIcon: String?

    var kind: WidgetActionKind { WidgetActionKind(rawValue: kindRaw) ?? .none }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Vehicle Action"
    static let defaultQuery = WidgetActionQuery()

    var displayRepresentation: DisplayRepresentation {
        if let presetVehicleName, presetId != nil {
            return DisplayRepresentation(
                title: "\(title)",
                subtitle: LocalizedStringResource(stringLiteral: presetVehicleName),
                image: .init(systemName: iconName)
            )
        }
        return DisplayRepresentation(title: "\(title)", image: .init(systemName: iconName))
    }

    // MARK: Fixed-action factories

    static func fixed(_ kind: WidgetActionKind) -> WidgetActionEntity {
        WidgetActionEntity(
            id: kind.rawValue,
            kindRaw: kind.rawValue,
            title: kind.defaultTitle,
            iconName: kind.icon
        )
    }

    static var lock: WidgetActionEntity { fixed(.lock) }
    static var unlock: WidgetActionEntity { fixed(.unlock) }
    static var startClimate: WidgetActionEntity { fixed(.startClimate) }
    static var stopClimate: WidgetActionEntity { fixed(.stopClimate) }
    static var none: WidgetActionEntity { fixed(.none) }

    /// Builds the full option list: the fixed commands plus one
    /// start-climate entry per known preset.
    static func allOptions(presets: [ClimatePresetEntity]) -> [WidgetActionEntity] {
        var options: [WidgetActionEntity] = [
            .lock,
            .unlock,
            .startClimate,
            .stopClimate,
            .fixed(.startCharge),
            .fixed(.stopCharge)
        ]
        for preset in presets {
            options.append(WidgetActionEntity(
                id: "preset:\(preset.id.uuidString)",
                kindRaw: WidgetActionKind.startClimate.rawValue,
                title: "Start Climate – \(preset.presetName)",
                iconName: preset.presetIcon,
                presetId: preset.id,
                presetVin: preset.vehicleVin,
                presetVehicleName: preset.vehicleName,
                presetName: preset.presetName,
                presetIcon: preset.presetIcon
            ))
        }
        options.append(.none)
        return options
    }
}

struct WidgetActionQuery: EntityQuery {
    func entities(for identifiers: [WidgetActionEntity.ID]) async throws -> [WidgetActionEntity] {
        let presets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
        let all = WidgetActionEntity.allOptions(presets: presets)
        // Preserve the caller's requested ordering.
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [WidgetActionEntity] {
        let presets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
        return WidgetActionEntity.allOptions(presets: presets)
    }
}

/// Per-slot options provider whose only job beyond listing the shared
/// options is supplying a slot-specific `defaultResult()`. The entity's
/// `defaultQuery` can only provide ONE default for every parameter of
/// the type, but each button slot wants a different pre-fill (Lock,
/// Unlock, …) — and `defaultResult` is also what the widget's Edit
/// screen displays, so without it the slots read as bare "Button 2" /
/// "Button 3" placeholders even though the widget renders defaults.
struct WidgetActionOptionsProvider: DynamicOptionsProvider {
    let defaultKind: WidgetActionKind

    func results() async throws -> [WidgetActionEntity] {
        let presets = (try? await ClimatePresetEntity.defaultQuery.suggestedEntities()) ?? []
        return WidgetActionEntity.allOptions(presets: presets)
    }

    func defaultResult() async -> WidgetActionEntity? {
        .fixed(defaultKind)
    }
}

struct VehicleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "Vehicle"
    static let defaultQuery = VehicleQuery()

    var id: UUID
    var displayName: String
    var vin: String
    var fuelType: FuelType
    /// Formatted "primary" range — EV for vehicles with electric
    /// capability, gas otherwise. Kept as the default surface for
    /// simple "what's my range" shortcuts; use `evRange` / `gasRange`
    /// for PHEVs that need both axes independently.
    @Property(title: "Range")
    var rangeText: String
    /// "Primary" percentage — EV battery for EVs, gas tank for ICE.
    /// Same compatibility role as `rangeText`. For unambiguous reads,
    /// use `evBatteryPercentage` / `gasFuelPercentage`.
    @Property(title: "Battery Percentage")
    var batteryPercentage: Double?
    var backgroundColorName: String
    var primaryColorName: String?
    var chargingColorName: String?
    var gasColorName: String?
    var lockColorName: String?
    var unlockColorName: String?
    var startClimateColorName: String?
    var stopColorName: String?
    var timestamp: Date
    var presets: [ClimatePresetEntity] = []

    // MARK: - Operational state (for Shortcuts conditionals)
    //
    // Each property is annotated with `@Property(title:)` so it shows
    // up with a localized label in the "Get Details of Vehicle"
    // picker in the Shortcuts editor. Without that annotation Apple
    // surfaces them with the raw camelCase name (or, on some OS
    // versions, hides them entirely under "Other Details").
    //
    // All operational state is optional because: the underlying
    // status may not have arrived yet for a new vehicle; or the
    // vehicle's fuel type doesn't support that signal (a pure ICE
    // car has no `pluggedIn`).

    @Property(title: "Is Locked")
    var isLocked: Bool?

    @Property(title: "Is Plugged In")
    var isPluggedIn: Bool?

    @Property(title: "Is Charging")
    var isCharging: Bool?

    @Property(title: "Charge Speed (kW)")
    var chargeSpeedKilowatts: Double?

    @Property(title: "Charge Time Remaining (minutes)")
    var chargeTimeRemainingMinutes: Int?

    @Property(title: "Target State of Charge")
    var targetStateOfCharge: Int?

    @Property(title: "Is Climate On")
    var isClimateOn: Bool?

    @Property(title: "Last Updated")
    var lastUpdated: Date?

    /// Vehicle's last reported latitude. Surfaced as a Number in
    /// Shortcuts so users can pipe it into Maps actions or do
    /// distance math against another coordinate.
    ///
    /// Originally tried to combine lat + lon into a single
    /// `CLPlacemark`-typed Location magic variable, but the only
    /// from-coords constructor (`MKPlacemark`) is deprecated in
    /// iOS / watchOS 26, and the App Intents framework's
    /// `_IntentValue` list doesn't include the replacement
    /// (`MKMapItem`) or even `CLLocation`. So separate Doubles
    /// it is until Apple updates App Intents.
    @Property(title: "Latitude")
    var latitude: Double?

    /// Vehicle's last reported longitude. See `latitude`.
    @Property(title: "Longitude")
    var longitude: Double?

    @Property(title: "Brand")
    var brand: String?

    // MARK: - Fuel-type-specific range + percentage
    //
    // The legacy `rangeText` / `batteryPercentage` pair has fuel-
    // type-dependent semantics (EV battery for EVs, gas tank for
    // ICE). The properties below are unambiguous: `evRange` only
    // populates for EV-capable vehicles, `gasRange` only for cars
    // with a gas tank. PHEVs populate BOTH, which is the only way
    // a Shortcut can read both readings off a single vehicle.

    /// Formatted EV range (e.g. "129 mi"). `nil` for ICE-only cars.
    @Property(title: "EV Range")
    var evRange: String?

    /// EV range as a raw number in the user's preferred distance
    /// unit — usable in Shortcuts math (e.g. "if EV Range Value
    /// is less than 50"). `nil` for ICE-only cars.
    @Property(title: "EV Range Value")
    var evRangeValue: Double?

    /// EV battery state of charge (0–100). `nil` for ICE-only cars.
    @Property(title: "EV Battery Percentage")
    var evBatteryPercentage: Double?

    /// Formatted gas range (e.g. "300 mi"). `nil` for pure EVs.
    @Property(title: "Gas Range")
    var gasRange: String?

    /// Gas range as a raw number in the user's preferred distance
    /// unit. `nil` for pure EVs.
    @Property(title: "Gas Range Value")
    var gasRangeValue: Double?

    /// Gas tank fill level (0–100). `nil` for pure EVs.
    @Property(title: "Gas Fuel Percentage")
    var gasFuelPercentage: Double?

    /// Whichever the legacy `Range` text uses — "mi" or "km" —
    /// reflecting the user's preferred distance unit at the moment
    /// this entity was built. Surfaced so a Shortcut can label a
    /// computed numeric range without guessing.
    @Property(title: "Range Unit")
    var rangeUnit: String?

    var primaryColor: Color { CustomColor.color(forName: primaryColorName, default: "blue") }
    var chargingColor: Color { CustomColor.color(forName: chargingColorName, default: "green") }
    var gasColor: Color { CustomColor.color(forName: gasColorName, default: "orange") }
    var lockColor: Color { CustomColor.color(forName: lockColorName, default: "red") }
    var unlockColor: Color { CustomColor.color(forName: unlockColorName, default: "green") }
    var startClimateColor: Color { CustomColor.color(forName: startClimateColorName, default: "blue") }
    var stopColor: Color { CustomColor.color(forName: stopColorName, default: "red") }

    var selectedPreset: ClimatePresetEntity? {
        presets.first(where: \.isSelected)
    }

    var displayRepresentation: DisplayRepresentation {
        // Subtitle gives the Shortcuts magic-variable chip useful
        // at-a-glance info — range + battery for EVs, range alone
        // for ICE. Without a subtitle, the chip is just the name.
        var subtitleParts: [String] = []
        if !rangeText.isEmpty, rangeText != "--" {
            subtitleParts.append(rangeText)
        }
        if let battery = batteryPercentage {
            subtitleParts.append("\(Int(battery))%")
        }
        let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(displayName)",
            subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) }
        )
    }

    // Get the gradient colors for the selected background
    var backgroundGradient: [Color] {
        guard let background = BBVehicle.availableBackgrounds.first(where: {
            $0.name == backgroundColorName
        }) else {
            return BBVehicle.availableBackgrounds[0].gradient
        }
        return background.gradient
    }

    init(
        id: UUID,
        displayName: String,
        vin: String,
        fuelType: FuelType,
        rangeText: String,
        batteryPercentage: Double?,
        timestamp: Date,
        backgroundColorName: String = "default",
        primaryColorName: String? = nil,
        chargingColorName: String? = nil,
        gasColorName: String? = nil,
        lockColorName: String? = nil,
        unlockColorName: String? = nil,
        startClimateColorName: String? = nil,
        stopColorName: String? = nil,
        presets: [ClimatePresetEntity] = []
    ) {
        // Non-wrapped properties first — `@Property` setters (used
        // below for rangeText/batteryPercentage) require self to be
        // fully initialized.
        self.id = id
        self.displayName = displayName
        self.vin = vin
        self.fuelType = fuelType
        self.timestamp = timestamp
        self.backgroundColorName = backgroundColorName
        self.primaryColorName = primaryColorName
        self.chargingColorName = chargingColorName
        self.gasColorName = gasColorName
        self.lockColorName = lockColorName
        self.unlockColorName = unlockColorName
        self.startClimateColorName = startClimateColorName
        self.stopColorName = stopColorName
        self.presets = presets

        // Wrapped properties — safe to set now that self is initialized.
        self.rangeText = rangeText
        self.batteryPercentage = batteryPercentage
    }

    init(from bbVehicle: BBVehicle, with unit: Distance.Units, allPresets: [ClimatePresetEntity]) {
        // STEP 1: assign every non-wrapped stored property. The
        // `@Property`-wrapped fields below have setters that go
        // through the wrapper, which requires `self` to be fully
        // initialized — so we have to finish the plain stored
        // properties before touching the wrapped ones.
        id = bbVehicle.id
        displayName = bbVehicle.displayName
        vin = bbVehicle.vin
        fuelType = bbVehicle.fuelType
        backgroundColorName = bbVehicle.backgroundColorName
        primaryColorName = bbVehicle.primaryColorName
        chargingColorName = bbVehicle.chargingColorName
        gasColorName = bbVehicle.gasColorName
        lockColorName = bbVehicle.lockColorName
        unlockColorName = bbVehicle.unlockColorName
        startClimateColorName = bbVehicle.startClimateColorName
        stopColorName = bbVehicle.stopColorName
        timestamp = bbVehicle.lastUpdated ?? Date()

        // Compute per-fuel-type range/percentage separately so PHEVs
        // (which have BOTH ev + gas data) populate both axes — and
        // so the unambiguous `evRange` / `gasRange` Shortcuts
        // properties always reflect their respective source. Each
        // tuple carries both the formatted text and the raw numeric
        // value (converted into the user's preferred unit) so
        // Shortcuts can branch on the number.
        let resolvedEV: (text: String?, value: Double?, percent: Double?) = {
            guard bbVehicle.fuelType.hasElectricCapability,
                  bbVehicle.modelContext != nil,
                  let ev = bbVehicle.evStatus,
                  ev.evRange.range.length > 0 else {
                return (nil, nil, nil)
            }
            let value = ev.evRange.range.units.convert(ev.evRange.range.length, to: unit)
            let text = ev.evRange.range.units.format(ev.evRange.range.length, to: unit)
            return (text, value, ev.evRange.percentage)
        }()
        let resolvedGas: (text: String?, value: Double?, percent: Double?) = {
            guard bbVehicle.modelContext != nil,
                  let gas = bbVehicle.gasRange,
                  gas.range.length > 0 else {
                return (nil, nil, nil)
            }
            let value = gas.range.units.convert(gas.range.length, to: unit)
            let text = gas.range.units.format(gas.range.length, to: unit)
            return (text, value, gas.percentage)
        }()

        // Legacy `rangeText` / `batteryPercentage` (kept for backward
        // compatibility): prefer EV for vehicles with electric
        // capability, fall back to gas. Empty-fallback text matches
        // the old behavior so existing user Shortcuts don't break.
        let legacyRangeText: String
        let legacyBatteryPercentage: Double?
        if bbVehicle.fuelType.hasElectricCapability {
            legacyRangeText = resolvedEV.text ?? "No EV data"
            legacyBatteryPercentage = resolvedEV.percent
        } else {
            legacyRangeText = resolvedGas.text ?? "No fuel data"
            legacyBatteryPercentage = resolvedGas.percent
        }
        // `presets` is plain (non-wrapped), set in step 1.
        // `rangeText` / `batteryPercentage` are @Property — defer
        // their assignment to step 2 below.
        presets = allPresets.filter { preset in preset.vehicleVin == vin }

        // STEP 2: now self is fully initialized — safe to assign
        // through `@Property` wrapped setters.
        rangeText = legacyRangeText
        batteryPercentage = legacyBatteryPercentage
        lastUpdated = bbVehicle.lastUpdated
        brand = bbVehicle.account?.brandEnum.displayName

        // Explicit per-fuel-type properties (computed above) —
        // formatted text + raw numeric value in the user's
        // preferred unit + percentage.
        evRange = resolvedEV.text
        evRangeValue = resolvedEV.value
        evBatteryPercentage = resolvedEV.percent
        gasRange = resolvedGas.text
        gasRangeValue = resolvedGas.value
        gasFuelPercentage = resolvedGas.percent
        rangeUnit = unit.abbreviation

        if bbVehicle.fuelType.hasElectricCapability,
           bbVehicle.modelContext != nil,
           let evStatus = bbVehicle.evStatus {
            // EV-only operational state. `chargeSpeed`, `chargeTime`,
            // and target SOC are only meaningful while plugged in /
            // charging, so leave them nil otherwise (rather than
            // zero) — that way Shortcuts conditionals like "if
            // chargeSpeed is set" do the right thing.
            isPluggedIn = evStatus.pluggedIn
            isCharging = evStatus.charging
            if evStatus.charging {
                chargeSpeedKilowatts = evStatus.chargeSpeed > 0 ? evStatus.chargeSpeed : nil
                let minutes = Int(evStatus.chargeTime.components.seconds / 60)
                chargeTimeRemainingMinutes = minutes > 0 ? minutes : nil
                if let target = evStatus.currentTargetSOC {
                    targetStateOfCharge = Int(target)
                }
            }
        }

        // Universal state (applies to all fuel types)
        if let lockStatus = bbVehicle.lockStatus {
            isLocked = lockStatus == .locked
        }
        if let climate = bbVehicle.climateStatus {
            isClimateOn = climate.airControlOn
        }
        if let loc = bbVehicle.location {
            latitude = loc.latitude
            longitude = loc.longitude
        }
    }
}

struct VehicleQuery: EntityQuery {
    func entities(
        for identifiers: [UUID],
    ) async throws -> [VehicleEntity] {
        let presets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        return try await MainActor.run {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)
            let context = ModelContext(modelContainer)

            let vehicles = try context.fetch(FetchDescriptor<BBVehicle>())
            // Live UserDefaults read — see `AppSettings.liveDistanceUnit`.
            let unit = AppSettings.liveDistanceUnit()

            return vehicles
                .filter { identifiers.contains($0.id) }
                .map { VehicleEntity(from: $0, with: unit, allPresets: presets) }
        }
    }

    func suggestedEntities() async throws -> [VehicleEntity] {
        let presets = try await ClimatePresetEntity.defaultQuery.suggestedEntities()
        return try await MainActor.run {
            let modelContainer = try createSharedModelContainer(enableCloudKit: false)
            let context = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<BBVehicle>(
                predicate: #Predicate { !$0.isHidden },
                sortBy: [SortDescriptor(\.sortOrder)],
            )

            let vehicles = try context.fetch(descriptor)
            let unit = AppSettings.liveDistanceUnit()

            return vehicles.map { VehicleEntity(from: $0, with: unit, allPresets: presets) }
        }
    }

    /// Pre-fills every vehicle parameter (widgets, Control Center
    /// controls, Shortcuts) with the user's primary vehicle — the first
    /// non-hidden one by sort order — instead of an empty "Vehicle"
    /// placeholder. With a single vehicle it is therefore always the
    /// default; with several, the user picks the default by reordering
    /// vehicles in Settings. Without this, an unconfigured control run
    /// from Spotlight/Control Center just errors with "edit this
    /// control and select a vehicle".
    func defaultResult() async -> VehicleEntity? {
        try? await suggestedEntities().first
    }
}
