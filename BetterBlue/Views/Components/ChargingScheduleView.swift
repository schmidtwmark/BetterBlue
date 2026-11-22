//
//  ChargingScheduleView.swift
//  BetterBlue
//
//  Sets when the vehicle's off-peak charging starts and stops. Nothing
//  else in its schedule changes: the write sends the rest back exactly as
//  the vehicle reported it.
//

import BetterBlueKit
import SwiftData
import SwiftUI

/// Sheet wrapper (from the vehicle sheet's charging menu and action list).
struct ChargingScheduleSheet: View {
    let vehicle: BBVehicle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ChargingScheduleContent(vehicle: vehicle)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Content view for navigation push (from Vehicle Info's EV Settings).
struct ChargingScheduleContent: View {
    let vehicle: BBVehicle
    @Environment(\.modelContext) private var modelContext

    @State private var start: Date
    @State private var end: Date
    @State private var isSaving = false
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var saveError: ActionError?
    @State private var successMessage: String?

    init(vehicle: BBVehicle) {
        self.vehicle = vehicle
        let schedule = vehicle.evStatus?.chargingSchedule
        let window = schedule?.offPeakWindow
        _start = State(initialValue: Self.date(for: window?.start ?? TimeOfDay(hour: 23, minute: 0)))
        _end = State(initialValue: Self.date(for: window?.end ?? TimeOfDay(hour: 7, minute: 0)))
    }

    private var schedule: ChargingSchedule? { vehicle.evStatus?.chargingSchedule }

    var body: some View {
        PersistentModelGuard(model: vehicle) {
            activeBody
        }
    }

    @ViewBuilder
    private var activeBody: some View {
        Form {
            if let ev = vehicle.evStatus, ev.isWaitingForScheduledCharge {
                Section {
                    WaitingToChargeLabel(evStatus: ev)
                }
            }

            if schedule == nil {
                Section {
                    Text("This vehicle hasn't reported a charging schedule yet.")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Text("Refresh Status")
                            if isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }
            }

            Section {
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Stop", selection: $end, displayedComponents: .hourAndMinute)
            } header: {
                Text("Off-Peak Hours")
            } footer: {
                if schedule?.offPeakEnabled == false {
                    Text("Off-peak charging is off for this vehicle, so it won't use these hours until it's turned on in the car or the brand's app.")
                }
            }
            .disabled(isSaving)

            if let saveError {
                Section {
                    ErrorDetailsView(error: saveError)
                }
            }

            if let successMessage {
                Section {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }

            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                            if let statusMessage {
                                Text(statusMessage).padding(.leading, 8)
                            }
                        } else {
                            Text("Save Schedule").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving || schedule == nil)
            }
        }
        .navigationTitle("Charging Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: start) { successMessage = nil }
        .onChange(of: end) { successMessage = nil }
        .onChange(of: schedule) { _, newSchedule in
            // A refresh brought the schedule in: show its values, unless
            // the user is mid-edit of an already-loaded one.
            guard !isSaving, let window = newSchedule?.offPeakWindow, successMessage == nil else { return }
            start = Self.date(for: window.start)
            end = Self.date(for: window.end)
        }
    }

    // MARK: - Actions

    @MainActor
    private func refresh() async {
        guard let account = vehicle.account else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        try? await account.fetchAndUpdateVehicleStatus(for: vehicle, modelContext: modelContext)
    }

    @MainActor
    private func save() {
        guard let account = vehicle.account else { return }

        let window = ChargingSchedule.OffPeakWindow(start: Self.timeOfDay(for: start), end: Self.timeOfDay(for: end))

        isSaving = true
        saveError = nil
        statusMessage = "Sending to vehicle..."

        Task {
            do {
                try await account.setOffPeakHours(vehicle, window: window, modelContext: modelContext)
                await confirm(window, account: account)
                // The vehicle accepted the write; a status that hasn't
                // caught up yet doesn't make it a failure.
                successMessage = "Schedule saved"
            } catch {
                saveError = ActionError(action: "Set charging schedule", error: error, accountId: account.id)
            }
            isSaving = false
            statusMessage = nil
        }
    }

    /// Checks the new hours took, starting the moment the write returns:
    /// the write only comes back once the vehicle has taken the change
    /// (13–31 seconds in MyHyundai's traffic), so there's nothing to wait
    /// for. The cached status goes first, since it's quick and doesn't
    /// wake the car, then the vehicle itself.
    @MainActor
    private func confirm(_ window: ChargingSchedule.OffPeakWindow, account: BBAccount) async {
        statusMessage = "Checking the vehicle..."
        try? await account.fetchAndUpdateVehicleStatus(for: vehicle, modelContext: modelContext, cached: true)
        guard vehicle.evStatus?.chargingSchedule?.offPeakWindow != window else { return }

        try? await vehicle.waitForStatusChange(
            modelContext: modelContext,
            condition: { $0.evStatus?.chargingSchedule?.offPeakWindow == window },
            statusMessageUpdater: { message in
                Task { @MainActor in self.statusMessage = message }
            },
            maxAttempts: 3,
            initialDelaySeconds: 0,
            retryDelaySeconds: 5,
            initialStatusMessage: "Checking the vehicle..."
        )
    }

    // MARK: - Time conversion

    private static func date(for time: TimeOfDay) -> Date {
        time.date(on: Date()) ?? Date()
    }

    private static func timeOfDay(for date: Date) -> TimeOfDay {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}

/// "Waiting to charge · starts 11:30 PM", with the car's estimated finish
/// when it gave one.
struct WaitingToChargeLabel: View {
    let evStatus: VehicleStatus.EVStatus

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                Label("Waiting to Charge", systemImage: "clock.badge")
                    .font(.headline)
                if let start = evStatus.expectedChargeStart(after: context.date) {
                    let startText = start.formatted(date: .omitted, time: .shortened)
                    let endText = evStatus.estimatedChargeEnd
                        .map { ", done around \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
                    Text("Starts \(startText)\(endText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
