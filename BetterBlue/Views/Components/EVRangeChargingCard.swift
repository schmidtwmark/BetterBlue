//
//  EVRangeChargingCard.swift
//  BetterBlue
//
//  Merged EV range display with charging controls
//

import BetterBlueKit
import SwiftData
import SwiftUI

struct EVRangeChargingCard: View {
    let bbVehicle: BBVehicle
    var transition: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared

    var evStatus: VehicleStatus.EVStatus? {
        guard bbVehicle.modelContext != nil else {
            print("⚠️ [EVRangeChargingCard] BBVehicle \(bbVehicle.vin) is detached from context")
            return nil
        }
        return bbVehicle.evStatus
    }

    var isCharging: Bool {
        evStatus?.charging ?? false
    }

    var isPluggedIn: Bool {
        evStatus?.pluggedIn ?? false
    }

    var formattedRange: String {
        guard let range = evStatus?.evRange.range, range.length > 0 else {
            return "--"
        }
        return range.units.format(range.length, to: appSettings.preferredDistanceUnit)
    }

    var batteryPercentage: Int {
        Int(evStatus?.evRange.percentage ?? 0)
    }

    var chargeSpeed: String? {
        guard isCharging, let evStatus, evStatus.chargeSpeed > 0 else {
            return nil
        }
        return String(format: "%.1f kW", evStatus.chargeSpeed)
    }

    var chargeTimeRemaining: String? {
        guard isCharging, let evStatus else {
            return nil
        }
        let duration = evStatus.chargeTime
        guard duration > .seconds(0) else {
            return nil
        }
        let formattedTime = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))

        // If there's a target SOC, append "to X%"
        if let targetSOC = evStatus.currentTargetSOC {
            return "\(formattedTime) to \(Int(targetSOC))%"
        }
        return formattedTime
    }

    var plugIcon: Image {
        bbVehicle.plugIcon(for: evStatus?.plugType)
    }

    @State private var inProgressAction: VehicleAction?
    @State private var message = ButtonMessage.empty
    @State private var currentTask: Task<Void, Never>?
    @State private var animatedDots = ""
    @State private var dotsTimer: Timer?

    var body: some View {
        let startCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(true, statusUpdater: statusUpdater)
            },
            icon: plugIcon,
            label: "Start Charge",
            inProgressLabel: "Starting Charge",
            completedText: "Charging started",
            color: .gray,
            menuIcon: Image(systemName: "bolt.fill")
        )

        let stopCharging = MainVehicleAction(
            action: { statusUpdater in
                try await setCharge(false, statusUpdater: statusUpdater)
            },
            icon: plugIcon,
            label: "Stop Charge",
            inProgressLabel: "Stopping Charge",
            completedText: "Charge stopped",
            color: .green,
            menuIcon: Image(systemName: "bolt.slash")
        )

        let currentAction = isCharging ? stopCharging : startCharging
        let allActions = isPluggedIn ? [startCharging, stopCharging] : []

        Menu {
            ForEach(Array(allActions.enumerated()), id: \.offset) { _, action in
                Button(action: {
                    currentTask = Task {
                        await performAction(action: action)
                    }
                }, label: {
                    let iconToUse = action.menuIcon ?? action.icon
                    Label {
                        Text(action.label)
                    } icon: {
                        iconToUse
                    }
                })
            }
        } label: {
            cardContent(currentAction: currentAction)
        }
        primaryAction: {
            if isPluggedIn {
                if inProgressAction != nil {
                    cancelCurrentOperation()
                } else {
                    currentTask = Task {
                        await performAction(action: currentAction)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardContent(currentAction: MainVehicleAction) -> some View {
        VStack(spacing: 12) {
            // Shared EV charging progress view
            EVChargingProgressView(
                icon: plugIcon,
                formattedRange: formattedRange,
                batteryPercentage: batteryPercentage,
                isCharging: isCharging,
                chargeSpeed: chargeSpeed,
                chargeTimeRemaining: chargeTimeRemaining,
                targetSOC: evStatus?.currentTargetSOC
            )

            // Bottom row: Status messages
            HStack {
                if let inProgressAction {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("\(inProgressAction.inProgressLabel)\(animatedDots)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 20, height: 20)

                        Image(systemName: "stop.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red)
                    }
                } else {
                    switch message {
                    case let .error(errorMessage):
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    case let .warning(warningMessage):
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text(warningMessage)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    case let .normal(normalMessage):
                        Text(normalMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .loading:
                        EmptyView()
                    case .empty:
                        if isPluggedIn {
                            Group {
                                if !isCharging {
                                    Text("Start Charging")
                                } else {
                                    Text("Stop Charging")
                                }
                            }.foregroundColor(.primary)
                                .font(.subheadline)
                            Spacer()
                        } else {
                            EmptyView()
                        }
                        
                    }
                }
                
            }
        }
        .padding()
        .vehicleCardGlassEffect()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Action Handling

    private func performAction(action: VehicleAction) async {
        startAction(action)

        do {
            try await action.action { message in
                Task { @MainActor in
                    self.message = .loading(message)
                }
            }
            handleActionSuccess(action)
        } catch is CancellationError {
            handleActionCancellation()
            return
        } catch {
            handleActionError(error)
            return
        }
    }

    @MainActor
    private func startAction(_ action: VehicleAction) {
        inProgressAction = action
        message = .loading("Sending command")
        startDotsAnimation()
    }

    @MainActor
    private func handleActionSuccess(_ action: VehicleAction) {
        stopDotsAnimation()
        inProgressAction = nil

        if let mainAction = action as? MainVehicleAction {
            let completedMessage = ButtonMessage.normal(mainAction.completedText)
            message = completedMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if message == completedMessage {
                        message = .empty
                    }
                }
            }
        } else {
            message = .empty
        }
        currentTask = nil
    }

    @MainActor
    private func handleActionCancellation() {
        stopDotsAnimation()
        inProgressAction = nil
        message = .empty
        currentTask = nil
    }

    @MainActor
    private func handleActionError(_ error: Error) {
        stopDotsAnimation()

        if let apiError = error as? APIError {
            switch apiError.errorType {
            case .concurrentRequest:
                message = .warning(apiError.message)
            case .serverError:
                message = .warning("Server temporarily unavailable")
            case .invalidPin:
                message = .error(apiError.message)
            default:
                message = .error(apiError.message)
            }
        } else {
            message = .error(error.localizedDescription)
        }

        inProgressAction = nil
        let errorMessage = message

        let timeout = message.isError() ? 4.0 : 7.0
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if message == errorMessage {
                    message = .empty
                }
            }
        }

        currentTask = nil
    }

    private func startDotsAnimation() {
        animatedDots = ""
        dotsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                switch animatedDots {
                case "":
                    animatedDots = "."
                case ".":
                    animatedDots = ".."
                case "..":
                    animatedDots = "..."
                default:
                    animatedDots = ""
                }
            }
        }
    }

    private func stopDotsAnimation() {
        dotsTimer?.invalidate()
        dotsTimer = nil
        animatedDots = ""
    }

    private func cancelCurrentOperation() {
        currentTask?.cancel()
        stopDotsAnimation()

        Task { @MainActor in
            await bbVehicle.clearPendingStatusWaiters()
        }

        let cancelMessage = ButtonMessage.normal("Canceled")

        withAnimation(.easeInOut(duration: 0.3)) {
            inProgressAction = nil
            message = cancelMessage
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if message == cancelMessage {
                    message = .empty
                }
            }
        }

        currentTask = nil
    }

    @MainActor
    private func setCharge(
        _ shouldStart: Bool,
        statusUpdater: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let account = bbVehicle.account else {
            throw APIError(message: "Account not found for vehicle")
        }

        let context = modelContext

        if shouldStart {
            try await account.startCharge(bbVehicle, modelContext: context)
        } else {
            try await account.stopCharge(bbVehicle, modelContext: context)

            // Immediately fetch status to update Live Activity
            do {
                try await account.fetchAndUpdateVehicleStatus(for: bbVehicle, modelContext: context)
            } catch {
                print("⚠️ [EVRangeChargingCard] Failed to fetch status after stop command: \(error)")
            }
        }

        try await bbVehicle.waitForStatusChange(
            modelContext: context,
            condition: { status in
                status.evStatus?.charging == shouldStart
            },
            statusMessageUpdater: statusUpdater
        )
    }
}
