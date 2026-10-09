//
//  CloudKitSyncMonitor.swift
//  BetterBlue
//
//  Observes NSPersistentCloudKitContainer.eventChangedNotification —
//  the only public signal SwiftData surfaces about its CloudKit sync
//  pipeline — and aggregates it into a single observable state object.
//
//  Use this to:
//    - Show "last import / export / setup succeeded at N minutes ago"
//      in the Diagnostics view.
//    - Surface specific CloudKit error messages (push registration
//      failed, account not signed in, schema mismatch, etc.) instead
//      of leaving the user staring at silently-broken sync.
//    - Run a "connectivity check" that proves the app can talk to
//      CloudKit at all (separate from whether SwiftData has actually
//      sync'd recently).
//
//  Install the singleton at app launch (`_ = CloudKitSyncMonitor.shared`
//  somewhere in BetterBlueApp / Watch app init) so we don't miss the
//  setup events that fire before the Diagnostics view is opened.
//

import CloudKit
import CoreData
import Foundation
import SwiftData

@MainActor
@Observable
final class CloudKitSyncMonitor {
    static let shared = CloudKitSyncMonitor()

    /// One discrete CloudKit-sync event surfaced by SwiftData. We keep
    /// a rolling history so the Diagnostics view can show "what's been
    /// happening" instead of just "what's the latest."
    struct Event: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let type: EventType
        let succeeded: Bool
        /// Localized error string when `succeeded` is false. Kept as a
        /// String so the struct stays `Sendable` and so we can ship it
        /// in the diagnostic export without dragging NSError along.
        let error: String?

        enum EventType: String, Sendable {
            case setup = "Setup"
            case `import` = "Import"
            case export = "Export"
            case unknown = "Unknown"
        }
    }

    /// Most recent event for each `EventType`. `nil` means we haven't
    /// seen that type yet (either it hasn't happened, or the app
    /// launched after it fired and we missed it).
    private(set) var lastSetup: Event?
    private(set) var lastImport: Event?
    private(set) var lastExport: Event?

    /// Rolling log of the last ~50 events, newest first. Surfaced in
    /// the diagnostic share so we can post-mortem broken syncs.
    private(set) var events: [Event] = []

    /// Filled in by `runConnectivityCheck`. Lets the Diagnostics view
    /// show a result panel without needing to round-trip through
    /// another @State property.
    private(set) var lastConnectivityCheck: ConnectivityCheckResult?

    struct ConnectivityCheckResult: Sendable {
        let date: Date
        let accountStatus: String
        let userRecordName: String?
        let containerHostReachable: Bool
        let error: String?

        var summary: String {
            if let error { return "Failed: \(error)" }
            return "OK — account \(accountStatus), userRecordName=\(userRecordName ?? "?")"
        }
    }

    private var observer: NSObjectProtocol?

    private init() {
        // `NSPersistentCloudKitContainer.eventChangedNotification` is
        // broadcast to the default notification center whenever ANY
        // CloudKit-backed Core Data / SwiftData store in the process
        // starts or finishes a setup / import / export. We can listen
        // without needing direct access to the underlying container.
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // `queue: .main` runs the closure on the main thread.
            // Project the CloudKit event into a Sendable `Event`
            // INSIDE the closure (where the non-Sendable
            // `NSPersistentCloudKitContainer.Event` stays put), then
            // hand only the Sendable copy across the actor boundary.
            let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            guard let ckEvent = note.userInfo?[key]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let identifier = ckEvent.identifier
            guard ckEvent.endDate != nil else {
                MainActor.assumeIsolated {
                    _ = self?.inFlightEvents.insert(identifier)
                }
                return
            }
            let projected = Event(
                date: ckEvent.endDate ?? Date(),
                type: Self.classify(ckEvent.type),
                succeeded: ckEvent.succeeded,
                error: Self.describe(ckEvent.error)
            )
            MainActor.assumeIsolated {
                self?.inFlightEvents.remove(identifier)
                self?.handle(projected)
            }
        }
    }

    /// Setup / import / export events that have started and not yet
    /// finished. While there are any, Core Data is (or may be) writing to
    /// the store.
    @ObservationIgnored private var inFlightEvents: Set<UUID> = []

    /// Waits until no CloudKit event is in flight, or until `deadline`.
    ///
    /// For work that has to finish before the app is suspended: a SQLite
    /// write in the App Group store still under way at suspension gets the
    /// app killed (0xdead10cc), and CloudKit mirroring writes on its own
    /// schedule — an export after every save, an import after every push.
    /// `grace` gives an event that a save just set off time to start before
    /// "idle" is believed.
    func waitUntilIdle(grace: Duration = .seconds(1), deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        try? await Task.sleep(until: min(deadline, clock.now + grace), clock: clock)
        while !inFlightEvents.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // No deinit — `CloudKitSyncMonitor` is a process-lifetime
    // singleton, so we never need to detach the observer. (And the
    // observer property is main-actor isolated, which would make a
    // nonisolated deinit awkward to write.)

    // MARK: - Event handling

    private func handle(_ event: Event) {
        events.insert(event, at: 0)
        if events.count > 50 {
            events.removeLast(events.count - 50)
        }

        switch event.type {
        case .setup:  lastSetup = event
        case .import: lastImport = event
        case .export: lastExport = event
        case .unknown: break
        }
    }

    nonisolated private static func classify(
        _ type: NSPersistentCloudKitContainer.EventType
    ) -> Event.EventType {
        switch type {
        case .setup:  return .setup
        case .import: return .import
        case .export: return .export
        @unknown default: return .unknown
        }
    }

    /// Build the most-actionable error string we can from the raw
    /// `Error` SwiftData hands us. `localizedDescription` alone is
    /// almost always "The operation couldn't be completed" — useless
    /// for triage. We pull the CKError code name (e.g.
    /// "partialFailure", "notAuthenticated"), the numeric code (so
    /// users can match against Apple's docs), and — for partial
    /// failures — the per-record error breakdown that CloudKit
    /// stashes in `partialErrorsByItemID`. Falls back to the raw
    /// NSError when nothing CloudKit-specific is present.
    nonisolated private static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError

        var lines: [String] = []
        lines.append("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")

        // Walk the full underlying-error chain. NSPersistentCloudKit-
        // Container loves to wrap the actual CKError two or three
        // levels deep under an NSCocoaErrorDomain shell — Cocoa
        // 134419 ("The operation couldn't be completed") is a
        // canonical example. We surface every level so the user's
        // diagnostic share contains the real cause, not just the
        // outermost generic wrapper. At EACH level we also pull the
        // partial-failure breakdown, since a top-level
        // `CKErrorDomain 2` (partialFailure) that didn't bridge to
        // `CKError` is exactly where the per-record reasons hide.
        var current: NSError? = nsError
        var depth = 0
        while let level = current {
            lines.append(contentsOf: partialFailureLines(from: level, indent: depth))
            guard let next = level.userInfo[NSUnderlyingErrorKey] as? NSError, depth < 6 else { break }
            depth += 1
            let indent = String(repeating: "  ", count: depth)
            if let ckCode = (next as? CKError)?.code ?? ckErrorCode(from: next) {
                lines.append("\(indent)↳ CKError.\(ckErrorCodeName(ckCode)) (\(next.code)): \(next.localizedDescription)")
            } else {
                lines.append("\(indent)↳ \(next.domain) \(next.code): \(next.localizedDescription)")
            }
            current = next
        }

        // Surface any non-standard userInfo keys at the top level
        // — NSPersistentCloudKitContainer sometimes attaches
        // `NSPersistentCloudKitContainerEventErrorKey` or the
        // specific `CKErrorRetryAfter` interval, which are useful
        // for triage. Skip the well-known keys we've already
        // covered to avoid noise.
        let knownKeys: Set<String> = [
            NSLocalizedDescriptionKey,
            NSLocalizedFailureReasonErrorKey,
            NSUnderlyingErrorKey,
            "NSLocalizedRecoverySuggestion",
            "CKErrorDescription"
        ]
        let extra = nsError.userInfo.filter { !knownKeys.contains($0.key) }
        if !extra.isEmpty {
            let summary = extra.keys.sorted().prefix(8).joined(separator: ", ")
            lines.append("userInfo keys: \(summary)")
        }

        return lines.joined(separator: "\n")
    }

    /// Extract a `CKError.Code` from an `NSError` that's already in
    /// `CKErrorDomain` but didn't bridge to `CKError` (happens with
    /// some chained-error situations where the bridge picks the
    /// outer Cocoa shell instead).
    nonisolated private static func ckErrorCode(from nsError: NSError) -> CKError.Code? {
        guard nsError.domain == CKErrorDomain else { return nil }
        return CKError.Code(rawValue: nsError.code)
    }

    /// Pull the per-record partial-failure breakdown straight out of
    /// `userInfo[CKPartialErrorsByItemIDKey]`. We read the key
    /// directly rather than via `CKError.partialErrorsByItemID`
    /// because the error SwiftData hands us is often a plain
    /// `NSError` in `CKErrorDomain` that doesn't bridge to `CKError`
    /// — in which case the convenience accessor is unreachable and
    /// the breakdown (the actual reason a `partialFailure` happened
    /// — e.g. a record rejected because the production CloudKit
    /// schema is missing a field) silently disappears.
    ///
    /// Capped at 5 entries so a sync with hundreds of bad records
    /// doesn't render an unreadable wall of text.
    nonisolated private static func partialFailureLines(from nsError: NSError, indent depth: Int) -> [String] {
        guard let partials = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
              !partials.isEmpty else {
            return []
        }
        let pad = String(repeating: "  ", count: depth)
        var lines = ["\(pad)Partial failures (\(partials.count) total, showing first 5):"]
        for (itemID, perItemError) in partials.prefix(5) {
            let inner = perItemError as NSError
            let innerCKCode = (perItemError as? CKError)?.code ?? ckErrorCode(from: inner)
            let innerCodeName = innerCKCode.map(ckErrorCodeName) ?? "(non-CK)"
            lines.append("\(pad)  • \(itemID): \(innerCodeName) — \(inner.localizedDescription)")
        }
        return lines
    }

    /// Map a `CKError.Code` raw value to the case name. Apple
    /// doesn't expose this — we maintain it by hand against the
    /// public CKError.Code enum. Worth the maintenance because the
    /// case name is what users / developers can search to find the
    /// fix (CKErrorDomain 2 means nothing; "partialFailure" is
    /// immediately greppable).
    // swiftlint:disable cyclomatic_complexity
    nonisolated private static func ckErrorCodeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError:                return "internalError"
        case .partialFailure:               return "partialFailure"
        case .networkUnavailable:           return "networkUnavailable"
        case .networkFailure:               return "networkFailure"
        case .badContainer:                 return "badContainer"
        case .serviceUnavailable:           return "serviceUnavailable"
        case .requestRateLimited:           return "requestRateLimited"
        case .missingEntitlement:           return "missingEntitlement"
        case .notAuthenticated:             return "notAuthenticated"
        case .permissionFailure:            return "permissionFailure"
        case .unknownItem:                  return "unknownItem"
        case .invalidArguments:             return "invalidArguments"
        case .resultsTruncated:             return "resultsTruncated"
        case .serverRecordChanged:          return "serverRecordChanged"
        case .serverRejectedRequest:        return "serverRejectedRequest"
        case .assetFileNotFound:            return "assetFileNotFound"
        case .assetFileModified:            return "assetFileModified"
        case .incompatibleVersion:          return "incompatibleVersion"
        case .constraintViolation:          return "constraintViolation"
        case .operationCancelled:           return "operationCancelled"
        case .changeTokenExpired:           return "changeTokenExpired"
        case .batchRequestFailed:           return "batchRequestFailed"
        case .zoneBusy:                     return "zoneBusy"
        case .badDatabase:                  return "badDatabase"
        case .quotaExceeded:                return "quotaExceeded"
        case .zoneNotFound:                 return "zoneNotFound"
        case .limitExceeded:                return "limitExceeded"
        case .userDeletedZone:              return "userDeletedZone"
        case .tooManyParticipants:          return "tooManyParticipants"
        case .alreadyShared:                return "alreadyShared"
        case .referenceViolation:           return "referenceViolation"
        case .managedAccountRestricted:     return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost:           return "serverResponseLost"
        case .assetNotAvailable:            return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        case .participantAlreadyInvited: return "participantAlreadyInvited"
            
        @unknown default:                   return "unknown(\(code.rawValue))"
        }
    }
    // swiftlint:enable cyclomatic_complexity

    // MARK: - Connectivity check (user-triggered)

    /// Probes CloudKit independently of SwiftData. Reports whether
    /// the iCloud account is signed in, whether we can reach the
    /// container (`fetchUserRecordID` round-trips), and stashes the
    /// result in `lastConnectivityCheck` for the UI.
    ///
    /// This proves the *network and account* path is healthy. If
    /// this passes but sync still isn't happening, the problem is
    /// almost certainly APNs (push environment mismatch in the app
    /// bundle's entitlements, e.g. a `development` aps-environment
    /// on a TestFlight build).
    func runConnectivityCheck(containerIdentifier: String) async {
        let container = CKContainer(identifier: containerIdentifier)
        let started = Date()

        do {
            let status = try await container.accountStatus()
            let userRecordID = try await container.userRecordID()
            lastConnectivityCheck = ConnectivityCheckResult(
                date: started,
                accountStatus: Self.describe(status),
                userRecordName: userRecordID.recordName,
                containerHostReachable: true,
                error: nil
            )
        } catch {
            // accountStatus or userRecordID failed — record whatever
            // status we got (or "Unknown" if even that errored) and
            // the error text so the user can copy it out.
            let accountStatus = (try? await container.accountStatus()).map(Self.describe) ?? "Unknown"
            lastConnectivityCheck = ConnectivityCheckResult(
                date: started,
                accountStatus: accountStatus,
                userRecordName: nil,
                containerHostReachable: false,
                error: error.localizedDescription
            )
        }
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:               return "Available"
        case .noAccount:               return "No Account"
        case .restricted:              return "Restricted"
        case .temporarilyUnavailable:  return "Temporarily Unavailable"
        case .couldNotDetermine:       return "Could Not Determine"
        @unknown default:              return "Unknown"
        }
    }
}
