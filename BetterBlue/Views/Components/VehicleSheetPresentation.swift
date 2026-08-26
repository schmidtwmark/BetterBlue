//
//  VehicleSheetPresentation.swift
//  BetterBlue
//
//  Single Observable that owns "which per-vehicle sheet is currently
//  showing" (info, account info, HTTP logs, trip details, climate
//  settings, charge-limit settings, vehicle configuration, structured
//  error details). Lives on `MainView` so its sheet survives the
//  `scenePhase != .active` view-tree swap that tears down
//  `PersistentVehicleSheet`. Same hoisting rationale as `MFAFlowState`.
//
//  Without this, each `@State private var showing* = false` on
//  `PersistentVehicleSheet` got reset to false the moment the user
//  briefly backgrounded the app, dismissing whatever the user was
//  reading.
//

import BetterBlueKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class VehicleSheetPresentation {
    /// Single-active-sheet model. SwiftUI's `.sheet(item:)` only
    /// supports one sheet per modifier, but we never need to show
    /// more than one of these at a time anyway — the user always
    /// dismisses one before triggering the next.
    enum Sheet: Identifiable {
        /// Structured error details. Carries the typed action error
        /// and a "clear" callback that wipes the originating
        /// `PersistentVehicleSheet`'s banner state. The callback is
        /// captured against the view that triggered the sheet; if
        /// that view has since been remounted (e.g. user
        /// backgrounded mid-triage), the call silently no-ops —
        /// the new view starts with an empty banner anyway, so
        /// the user-visible outcome is the same.
        case errorDetails(error: ActionError, onClear: @MainActor () -> Void)
        case vehicleInfo(vehicle: BBVehicle)
        case accountInfo(account: BBAccount)
        case httpLogs(account: BBAccount)
        case vehicleConfiguration(vehicle: BBVehicle)
        case tripDetails(vehicle: BBVehicle)
        case surroundView(vehicle: BBVehicle)
        case climateSettings(vehicle: BBVehicle)
        case chargeLimitSettings(vehicle: BBVehicle)

        /// `Identifiable` for `.sheet(item:)`. Embedding the
        /// vehicle/account id means re-triggering on the *same*
        /// vehicle is a no-op (SwiftUI sees the same id and
        /// doesn't re-present), but switching to another vehicle's
        /// sheet of the same kind correctly re-presents.
        var id: String {
            switch self {
            case .errorDetails: return "errorDetails"
            case .vehicleInfo(let v): return "vehicleInfo:\(v.id)"
            case .accountInfo(let a): return "accountInfo:\(a.id)"
            case .httpLogs(let a): return "httpLogs:\(a.id)"
            case .vehicleConfiguration(let v): return "vehicleConfiguration:\(v.id)"
            case .tripDetails(let v): return "tripDetails:\(v.id)"
            case .surroundView(let v): return "surroundView:\(v.id)"
            case .climateSettings(let v): return "climateSettings:\(v.id)"
            case .chargeLimitSettings(let v): return "chargeLimitSettings:\(v.id)"
            }
        }
    }

    var active: Sheet?

    func show(_ sheet: Sheet) { active = sheet }
    func dismiss() { active = nil }
}
