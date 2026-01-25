//
//  AppLogger.swift
//  BetterBlue
//
//  Unified logging using OSLog for debugging background processes, intents, and live activities.
//  View logs in Console.app by filtering for "com.markschmidt.BetterBlue"
//

import BetterBlueKit
import OSLog

/// Centralized logging for BetterBlue using OSLog
/// Logs persist and can be viewed in Console.app even for background processes
///
/// Usage:
///   AppLogger.liveActivity.info("Starting activity")
///   AppLogger.intent.debug("Processing intent")
///   AppLogger.api.error("Request failed: \(error)")
///
/// To view logs:
///   1. Open Console.app on Mac
///   2. Select your device (connect via cable or same network)
///   3. Filter by "com.markschmidt.BetterBlue" or category name
///   4. Make sure to enable "Include Info Messages" and "Include Debug Messages" in Action menu
enum AppLogger {
    private static let subsystem = "com.markschmidt.BetterBlue"

    /// Live Activity related logs
    static let liveActivity = Logger(subsystem: subsystem, category: "LiveActivity")

    /// App Intent logs (widgets, shortcuts, control center)
    static let intent = Logger(subsystem: subsystem, category: "Intent")

    /// API/Network logs
    static let api = Logger(subsystem: subsystem, category: "API")

    /// Background task logs
    static let background = Logger(subsystem: subsystem, category: "Background")

    /// Push notification logs
    static let push = Logger(subsystem: subsystem, category: "Push")

    /// MFA/Authentication logs
    static let auth = Logger(subsystem: subsystem, category: "Auth")

    /// General app logs
    static let app = Logger(subsystem: subsystem, category: "App")

    /// Vehicle operations logs
    static let vehicle = Logger(subsystem: subsystem, category: "Vehicle")

    /// Fake API logs (testing)
    static let fakeAPI = Logger(subsystem: subsystem, category: "FakeAPI")

    /// MFA-specific logs
    static let mfa = Logger(subsystem: subsystem, category: "MFA")
}

// MARK: - OSLog Sink for BetterBlueKit

/// Log sink that bridges BetterBlueKit's BBLogger to OSLog via AppLogger.
/// Configure this at app startup: `BBLogger.sink = OSLogSink.shared`
final class OSLogSink: BBLogSink, @unchecked Sendable {
    static let shared = OSLogSink()

    private init() {}

    func log(level: BBLogLevel, category: BBLogCategory, message: String) {
        let logger = logger(for: category)

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }

    private func logger(for category: BBLogCategory) -> Logger {
        switch category {
        case .api:
            return AppLogger.api
        case .auth:
            return AppLogger.auth
        case .mfa:
            return AppLogger.mfa
        case .liveActivity:
            return AppLogger.liveActivity
        case .intent:
            return AppLogger.intent
        case .background:
            return AppLogger.background
        case .push:
            return AppLogger.push
        case .app:
            return AppLogger.app
        case .vehicle:
            return AppLogger.vehicle
        case .fakeAPI:
            return AppLogger.fakeAPI
        }
    }
}
