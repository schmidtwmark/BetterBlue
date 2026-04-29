//
//  HTTPLog.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/6/25.
//
import BetterBlueKit
import Foundation
import SwiftData

enum DeviceType: String, Codable, CaseIterable {
    case iPhone
    case iPad
    case mac = "Mac"
    // `.menuBar` lands in main as a forward-compat declaration only — the
    // Mac menu bar app itself lives on the `mac-app` branch. We keep the
    // case here so SwiftData/CloudKit can decode any `BBHTTPLog` rows that
    // were synced from a device running the menu bar build; without it,
    // loading those rows crashes the HTTP Log view.
    case menuBar = "Menu Bar"
    case widget = "Widget"
    case watch = "Watch"
    case liveActivity = "Live Activity"

    var displayName: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .mac: return "Mac"
        case .menuBar: return "Menu Bar"
        case .widget: return "Widget"
        case .watch: return "Watch"
        case .liveActivity: return "Live Activity"
        }
    }
}

@Model
class BBHTTPLog {
    var log: HTTPLog = HTTPLog(
        timestamp: Date(),
        accountId: UUID(),
        requestType: .fetchVehicleStatus,
        method: "",
        url: "",
        requestHeaders: [:],
        requestBody: nil,
        responseStatus: nil,
        responseHeaders: [:],
        responseBody: nil,
        error: nil,
        duration: 0,
    )

    var deviceType: DeviceType = DeviceType.iPhone

    init(log: HTTPLog, deviceType: DeviceType = DeviceType.iPhone) {
        self.log = log
        self.deviceType = deviceType
    }
}
