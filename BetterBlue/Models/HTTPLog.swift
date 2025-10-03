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
    case widget = "Widget"
    case watch = "Watch"

    var displayName: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .mac: return "Mac"
        case .widget: return "Widget"
        case .watch: return "Watch"
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
