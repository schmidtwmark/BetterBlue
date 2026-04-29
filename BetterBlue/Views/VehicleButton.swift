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
    /// Full error context for the most recent failed action. Drives the
    /// "Show last error…" item that's appended to the action menu when
    /// set, plus the details sheet it opens. Kept around alongside the
    /// compact chip state so users can drill in without losing the chip.
    @State private var lastActionError: ActionError?
    @State private var showingErrorDetails = false
    /// Drives the click-to-show actions popover on macOS. On iOS the
    /// status button is a SwiftUI `Menu` so this state is unused.
    @State private var showingActionPopover = false
    let bbVehicle: BBVehicle

    var currentAction: MainVehicleAction {
        currentActionDeterminant()
    }

    /// The icon to use for the quick action button
    private var quickActionIcon: Image {
        currentAction.menuIcon ?? currentAction.icon
    }

    /// Fixed height for both the status section and quick action button
    private let buttonHeight: CGFloat = 52

    /// Fixed width for status icons to ensure text alignment
    private let statusIconWidth: CGFloat = 24

    var body: some View {
        PersistentModelGuard(model: bbVehicle) {
            HStack(spacing: 8) {
                // Left side: Status display with context menu
                statusButton

                // Right side: Quick action button
                quickActionButton
            }
            .fixedSize(horizontal: false, vertical: true)
            .sheet(isPresented: $showingErrorDetails) {
                // Jump straight to the full details sheet — the menu item is
                // already an explicit "show me the error" affordance.
                if let lastActionError {
                    ErrorDetailsSheet(error: lastActionError) {
                        showingErrorDetails = false
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
    }

    // MARK: - Status Button (Left Side)

    @ViewBuilder
    private var statusButton: some View {
        #if os(macOS)
        // On macOS even `.menuStyle(.borderlessButton)` ends up stripping
        // custom label modifiers (`.vehicleCardGlassEffect()` in
        // particular), rendering the label as a flat NSPopUpButton-style
        // text + chevron rather than the iPad-style glass card. To keep
        // the visual identical to the rest of the app, use a plain
        // Button with a popover for click and `.contextMenu` for
        // right-click — the same pattern as the quick action button.
        Button {
            showingActionPopover = true
        } label: {
            statusButtonLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingActionPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                actionMenuContent
            }
            .frame(minWidth: 220)
            .padding(8)
        }
        .contextMenu {
            actionMenuContent
        }
        #else
        Menu {
            actionMenuContent
        } label: {
            statusButtonLabel
        }
        #endif
    }

    @ViewBuilder
    private var statusButtonLabel: some View {
        HStack {
            // State icon and label
            if let inProgressAction {
                Text("\(inProgressAction.inProgressLabel)\(animatedDots)")
                    .foregroundColor(.primary)
                    .font(.subheadline)
            } else {
                currentAction.icon
                    .foregroundColor(currentAction.color)
                    .spin(currentAction.shouldRotate)
                    .pulse(currentAction.shouldPulse)
                    .frame(width: statusIconWidth)
                Text(currentAction.stateLabel)
                    .foregroundColor(.primary)
                    .font(.subheadline)
            }

            Spacer()

            // Message display
            messageView
        }
        .padding()
        .frame(height: buttonHeight)
        .vehicleCardGlassEffect()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Quick Action Button (Right Side)

    @ViewBuilder
    private var quickActionButton: some View {
        // Plain Button + .contextMenu (rather than Menu + primaryAction)
        // so the custom glass-effect label renders verbatim on every
        // platform. The long-press / right-click menu is attached via
        // .contextMenu — works the same on iOS (long-press) and macOS
        // (right-click or Control-click). Avoids the native AppKit
        // popup-button chrome that Menu renders on macOS.
        Button {
            if inProgressAction != nil {
                cancelCurrentOperation()
            } else {
                currentTask = Task {
                    await performAction(action: currentAction)
                }
            }
        } label: {
            quickActionButtonLabel
        }
        .buttonStyle(.plain)
        .contextMenu {
            actionMenuContent
        }
    }

    @ViewBuilder
    private var quickActionButtonLabel: some View {
        Group {
            if inProgressAction != nil {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                quickActionIcon
                    .foregroundColor(currentAction.quickActionColor)
            }
        }
        .frame(width: buttonHeight, height: buttonHeight)
        .vehicleCardGlassEffect()
        .contentShape(Rectangle())
    }

    // MARK: - Shared Menu Content

    @ViewBuilder
    private var actionMenuContent: some View {
        // When the most recent command failed, surface a quick shortcut to
        // the full error details. Compact chip stays as-is; users who want
        // the raw response / HTTP log long-press and pick this item.
        if lastActionError != nil {
            Button {
                showingActionPopover = false
                showingErrorDetails = true
            } label: {
                Label("Show Last Error…", systemImage: "exclamationmark.triangle")
            }
            Divider()
        }

        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action: {
                // Dismiss the macOS popover (no-op on iOS, where this is
                // already inside a Menu that auto-dismisses).
                showingActionPopover = false
                currentTask = Task {
                    await performAction(action: action)
                }
            }, label: {
                let iconToUse = (action as? MainVehicleAction)?.menuIcon ?? action.icon
                Label {
                    Text(action.label)
                } icon: {
                    iconToUse
                }
            })
        }
    }

    // MARK: - Message View

    @ViewBuilder
    private var messageView: some View {
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
            if !currentAction.additionalText.isEmpty {
                Text(currentAction.additionalText)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        // Success clears the "Show Last Error…" shortcut so stale failures
        // don't linger in the menu.
        lastActionError = nil

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

        // Record the full error context so the menu's "Show Last Error…"
        // shortcut (and the attached sheet) can render the three-part
        // treatment (action, type, technical details).
        let actionLabel = (inProgressAction as? MainVehicleAction)?.completedText
            ?? inProgressAction?.label
            ?? currentAction.label
        lastActionError = ActionError(
            action: actionLabel,
            error: error,
            accountId: bbVehicle.account?.id
        )

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
