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
import SwiftData
import UIKit

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private init() {}

    func updateActivity(for vehicle: BBVehicle, status: VehicleStatus, modelContext: ModelContext) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var type: LiveActivityType = .none
        
        if status.climateStatus.airControlOn {
            type = .climate
        } else if status.evStatus?.charging == true {
            type = .charging
        }

        if type != .none {
            startOrUpdateActivity(for: vehicle, status: status, type: type)

            // TODO: send a notification to the APNs server to start receiving pings every N seconds
            // On receiving a ping, go fetch the vehicle status.
        } else {
            endActivity(for: vehicle)
            // TODO: stop listening for APNs updates
        }
        #endif
    }
    
    func startCommandActivity(for vehicle: BBVehicle, type: LiveActivityType, modelContext: ModelContext) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        guard let status = createStatusFromVehicle(vehicle) else {
            print("⚠️ [LiveActivity] Could not create status from vehicle for command activity")
            return
        }
        
        startOrUpdateActivity(for: vehicle, status: status, type: type)
        
        // Start a background task to refresh
        Task {
            // Safely access UIApplication using dynamic dispatch to avoid extension build errors
            var taskId = UIBackgroundTaskIdentifier.invalid
            var app: UIApplication? = nil
            
            if let cls = NSClassFromString("UIApplication") as? NSObject.Type {
                let selector = NSSelectorFromString("sharedApplication")
                if cls.responds(to: selector) {
                    app = cls.perform(selector)?.takeUnretainedValue() as? UIApplication
                }
            }
            
            if let application = app {
                taskId = application.beginBackgroundTask(withName: "LiveActivityCommandRefresh") {
                    print("⚠️ [LiveActivity] Background task expired")
                }
            }
            
            do {
                for i in 1...3 {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    print("🔄 [LiveActivity] Command refresh attempt \(i)/3")
                    
                    guard let account = vehicle.account else { break }
                    try await account.fetchAndUpdateVehicleStatus(for: vehicle, modelContext: modelContext)
                    
                    // Check if state changed to what we expect
                    if (type == .climate && vehicle.climateStatus?.airControlOn == true) ||
                        (type == .charging && vehicle.evStatus?.charging == true) {
                        print("✅ [LiveActivity] State change detected, stopping command refresh loop")
                        break
                    }
                }
                
                if (type == .climate && vehicle.climateStatus?.airControlOn != true) ||
                    (type == .charging && vehicle.evStatus?.charging != true) {
                    print("❌ [LiveActivity] State did not change after retries")
                    startOrUpdateActivity(for: vehicle, status: createStatusFromVehicle(vehicle) ?? status, type: type)
                    
                    // Keep it for a bit then kill it?
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    endActivity(for: vehicle)
                }
                
            } catch {
                print("❌ [LiveActivity] Command refresh task failed: \(error)")
            }
            
            if let application = app, taskId != .invalid {
                application.endBackgroundTask(taskId)
            }
        }
        #endif
    }
    
    private func createStatusFromVehicle(_ vehicle: BBVehicle) -> VehicleStatus? {
        // Helper to reconstruct VehicleStatus from BBVehicle parts
        // This is a bit duplicative of what might be in BBVehicle or APIClient, but necessary here
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

    private func startOrUpdateActivity(
        for vehicle: BBVehicle,
        status: VehicleStatus,
        type: LiveActivityType,
    ) {
        #if canImport(ActivityKit)

        let contentState = VehicleActivityAttributes.ContentState(
            status: status,
            activityType: type
        )

        let existingActivity = Activity<VehicleActivityAttributes>.activities.first { $0.attributes.vin == vehicle.vin }

        if let activity = existingActivity {
            Task {
                await activity.update(ActivityContent(state: contentState, staleDate: nil))
            }
        } else {
            let attributes = VehicleActivityAttributes(
                vehicleName: vehicle.displayName,
                vin: vehicle.vin,
                vehicleId: vehicle.id
            )
            do {
                _ = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: nil),
                    pushType: nil
                )
            } catch {
                print("Error requesting Live Activity: \(error)")
            }
        }
        #endif
    }

    private func endActivity(for vehicle: BBVehicle) {
        #if canImport(ActivityKit)
        let existingActivity = Activity<VehicleActivityAttributes>.activities.first { $0.attributes.vin == vehicle.vin }
        if let activity = existingActivity {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }
}


public enum LiveActivityState: String, Codable, Hashable, Sendable {
    case starting
    case running
    case failed
}

public enum LiveActivityType: String, Codable, Hashable, Sendable {
    case climate
    case charging
    case none

    public func message(for state: LiveActivityState) -> String {
        switch (self, state) {
        case (.climate, .starting): return "Starting Climate..."
        case (.climate, .running): return "Climate Active"
        case (.climate, .failed): return "Climate Failed"
        
        case (.charging, .starting): return "Starting Charge..."
        case (.charging, .running): return "Charging"
        case (.charging, .failed): return "Charge Failed"
            
        case (.none, .starting): return "Updating..."
        case (.none, .running): return "Updated"
        case (.none, .failed): return "Update Failed"
        }
    }

    public var refreshInterval: TimeInterval {
        switch self {
        case .climate: return 120 // 2 minutes
        case .charging: return 600 // 10 minutes
        case .none: return 3600 // 1 hour
        }
    }
}

#if canImport(ActivityKit)
import ActivityKit
import BetterBlueKit

public struct VehicleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: VehicleStatus
        public var activityType: LiveActivityType
        public var activityState: LiveActivityState
        
        public init(status: VehicleStatus, activityType: LiveActivityType = .none, activityState: LiveActivityState = .running) {
            self.status = status
            self.activityType = activityType
            self.activityState = activityState
        }
    }

    public var vehicleName: String
    public var vin: String
    public var vehicleId: UUID
    
    public init(vehicleName: String, vin: String, vehicleId: UUID) {
        self.vehicleName = vehicleName
        self.vin = vin
        self.vehicleId = vehicleId
    }
}
#endif
