//
//  WidgetCommandStatus.swift
//  BetterBlueWidget
//
//  Tiny app-group store recording the last command a user triggered
//  from a widget button. Lets the widget optimistically show
//  "<command> requested at <time>" in place of the last-updated time
//  until a real status refresh supersedes it.
//

import Foundation

enum WidgetCommandStatus {
    // Same app group the shared SwiftData store + AppSettings use, so
    // the value written by the button intent is visible to the widget.
    private static let suiteName = AppIdentifiers.appGroup
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }
    private static func key(_ vin: String) -> String { "widgetCommand.\(vin)" }

    /// Record that `command` was requested for `vin` at `date` (default
    /// now). Both values are plist types so they round-trip through
    /// UserDefaults.
    static func record(command: String, vin: String, at date: Date = Date()) {
        defaults?.set(["command": command, "date": date], forKey: key(vin))
    }

    /// The last command requested for `vin`, if any.
    static func latest(vin: String) -> (command: String, date: Date)? {
        guard let dict = defaults?.dictionary(forKey: key(vin)),
              let command = dict["command"] as? String,
              let date = dict["date"] as? Date else {
            return nil
        }
        return (command, date)
    }

    /// Default window in which an identical repeat of a command is treated
    /// as a duplicate delivery rather than a second deliberate request.
    static let duplicateWindow: TimeInterval = 15

    /// Claims the right to send `command` for `vin`, recording it as the
    /// pending command. Returns `false` — writing nothing — when the same
    /// command was already recorded within `window`.
    ///
    /// Command intents are reachable from surfaces that can fire without a
    /// deliberate tap (Lock Screen / Control Center controls, Siri, Shortcuts)
    /// and the system may re-deliver an intent it thinks didn't complete. A
    /// repeat inside this window is therefore far more likely to be a
    /// duplicate delivery than a user asking twice, and acting on it sends a
    /// second lock/unlock to the vehicle (BetterBlue#94).
    ///
    /// Backed by the shared app group, so it holds across the app and the
    /// widget/intent extension processes.
    static func beginCommand(
        _ command: String,
        vin: String,
        within window: TimeInterval = duplicateWindow
    ) -> Bool {
        if let last = latest(vin: vin),
           last.command == command,
           Date().timeIntervalSince(last.date) < window {
            return false
        }
        record(command: command, vin: vin)
        return true
    }

    /// Drops the pending-command record for `vin`. Called when a command
    /// fails, so the widget stops advertising a request that didn't happen
    /// and an immediate retry isn't mistaken for a duplicate.
    static func clear(vin: String) {
        defaults?.removeObject(forKey: key(vin))
    }
}
