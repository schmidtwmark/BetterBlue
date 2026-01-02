//
//  VehicleButton.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 7/11/25.
//

import BetterBlueKit
import SwiftData
import SwiftUI

enum ButtonMessage: Equatable {
    case error(String)
    case warning(String)
    case loading(String)
    case normal(String)
    case empty

    func isError() -> Bool {
        switch self {
        case .error:
            true
        default:
            false
        }
    }
}

// Generic vehicle control button that handles common functionality
struct VehicleControlButton: View {
    let actions: [VehicleAction]
    let currentActionDeterminant: () -> MainVehicleAction
    var transition: Namespace.ID?
    @State private var inProgressAction: VehicleAction?
    @State private var message = ButtonMessage.empty
    @State private var currentTask: Task<Void, Never>?
    @State private var currentActionIndex: Array.Index = 0
    @State private var animatedDots = ""
    @State private var dotsTimer: Timer?
    let bbVehicle: BBVehicle

    var currentAction: MainVehicleAction {
        currentActionDeterminant()
    }

    var body: some View {
        Menu {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action: {
                    currentTask = Task {
                        await performAction(action: action)
                    }
                }, label: {
                    let iconToUse = (action as? MainVehicleAction)?.menuIcon ??
                        action.icon
                    Label(action.label, systemImage: iconToUse)
                })
            }
        } label: {
            HStack {
                if let inProgressAction {
                    ProgressView()
                    Text(
                        "\(inProgressAction.inProgressLabel)\(animatedDots)",
                    )
                    .foregroundColor(.primary)
                    .font(.subheadline)

                } else {
                    Image(systemName: currentAction.icon)
                        .foregroundColor(currentAction.color)
                        .spin(currentAction.shouldRotate)
                        .pulse(currentAction.shouldPulse)
                    Text(currentAction.label)
                        .foregroundColor(.primary)
                        .font(.subheadline)
                }

                Spacer()

                switch message {
                case let .error(errorMessage):
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                case let .warning(warningMessage):
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(warningMessage)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                case let .loading(loadingMessage):
                    Text(loadingMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                case let .normal(normalMessage):
                    Text(normalMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .empty:
                    Text(currentAction.additionalText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if inProgressAction != nil {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 24, height: 24)

                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
            }
            .padding()
            .glassEffect()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        primaryAction: {
            if inProgressAction != nil {
                cancelCurrentOperation()
            } else {
                currentTask = Task {
                    await performAction(action: currentAction)
                }
            }
        }
    }

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
}
