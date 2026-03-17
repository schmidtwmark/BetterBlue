//
//  AppSettings.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 8/3/25.
//

import BetterBlueKit
import Foundation
import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
    import ActivityKit
#endif

#if canImport(UserNotifications)
    import UserNotifications
#endif

enum WidgetRefreshInterval: Int, CaseIterable {
    case oneHour = 1
    case twoHours = 2
    case threeHours = 3
    case fourHours = 4
    case sixHours = 6
    case twelveHours = 12

    var displayName: String {
        switch self {
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .threeHours:
            return "3 hours"
        case .fourHours:
            return "4 hours"
        case .sixHours:
            return "6 hours"
        case .twelveHours:
            return "12 hours"
        }
    }

    var timeInterval: TimeInterval {
        return TimeInterval(rawValue * 3600) // Convert hours to seconds
    }
}

@MainActor @Observable
class AppSettings {
    static let shared = AppSettings()

    private let userDefaults = UserDefaults(suiteName: "group.com.betterblue.shared")!
    private let distanceUnitKey = "DistanceUnit"
    private let temperatureUnitKey = "TemperatureUnit"
    private let notificationsEnabledKey = "NotificationsEnabled"
    private let widgetRefreshIntervalKey = "WidgetRefreshInterval"
    private let debugModeEnabledKey = "DebugModeEnabled"
    private let liveActivitiesEnabledKey = "LiveActivitiesEnabled"

    var preferredDistanceUnit: Distance.Units {
        get {
            let savedValue = userDefaults.string(forKey: distanceUnitKey) ?? Distance.Units.miles.rawValue
            return Distance.Units(rawValue: savedValue) ?? .miles
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: distanceUnitKey)
            refreshWidgetsAndLiveActivities()
        }
    }

    var preferredTemperatureUnit: Temperature.Units {
        get {
            let savedValue = userDefaults.string(forKey: temperatureUnitKey) ?? Temperature.Units.fahrenheit.rawValue
            return Temperature.Units(rawValue: savedValue) ?? .fahrenheit
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: temperatureUnitKey)
            refreshWidgetsAndLiveActivities()
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: notificationsEnabledKey)
            if notificationsEnabled {
                #if canImport(UserNotifications)
                    Task {
                        await requestNotificationPermission()
                    }
                #endif
            }
        }
    }

    var widgetRefreshInterval: WidgetRefreshInterval {
        didSet {
            userDefaults.set(widgetRefreshInterval.rawValue, forKey: widgetRefreshIntervalKey)
        }
    }

    var debugModeEnabled: Bool {
        didSet {
            userDefaults.set(debugModeEnabled, forKey: debugModeEnabledKey)
        }
    }

    var liveActivitiesEnabled: Bool {
        didSet {
            userDefaults.set(liveActivitiesEnabled, forKey: liveActivitiesEnabledKey)
        }
    }

    private init() {
        notificationsEnabled = userDefaults.bool(forKey: notificationsEnabledKey)

        let savedRefreshInterval = userDefaults.integer(forKey: widgetRefreshIntervalKey)
        widgetRefreshInterval = WidgetRefreshInterval(rawValue: savedRefreshInterval) ?? .fourHours

        if userDefaults.object(forKey: debugModeEnabledKey) == nil {
            #if DEBUG
                debugModeEnabled = true
            #else
                debugModeEnabled = false
            #endif
        } else {
            debugModeEnabled = userDefaults.bool(forKey: debugModeEnabledKey)
        }

        // Live Activities is a beta feature, disabled by default
        liveActivitiesEnabled = userDefaults.bool(forKey: liveActivitiesEnabledKey)
    }

    private func requestNotificationPermission() async {
        #if canImport(UserNotifications)
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    BBLogger.info(.push, "Notifications: Permission granted")
                } else {
                    BBLogger.warning(.push, "Notifications: Permission denied")
                    await MainActor.run {
                        notificationsEnabled = false
                    }
                }
            } catch {
                BBLogger.error(.push, "Notifications: Permission request failed: \(error)")
                await MainActor.run {
                    notificationsEnabled = false
                }
            }
        #endif
    }

    private func refreshWidgetsAndLiveActivities() {
        
        // Refresh all widgets to pick up the new unit settings
        BBLogger.info(.app, "Refreshing widget and live activities")
        WidgetCenter.shared.reloadAllTimelines()

        // Refresh all live activities to pick up the new unit settings
        #if canImport(ActivityKit)
            for activity in Activity<VehicleActivityAttributes>.activities {
                Task {
                    let currentState = activity.content.state
                    await activity.update(ActivityContent(state: currentState, staleDate: nil))
                }
            }
        #endif
    }
}
