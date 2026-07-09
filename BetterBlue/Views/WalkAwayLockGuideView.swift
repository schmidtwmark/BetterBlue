//
//  WalkAwayLockGuideView.swift
//  BetterBlue
//
//  Setup guide for walk-away lock. iOS gives apps no background hook for
//  CarPlay disconnects (audio-route notifications only arrive while the
//  app is running, and the GPS/geofence alternative is invasive), so the
//  sanctioned mechanism is a Shortcuts personal automation. This screen
//  hands users a pre-built Shortcut composed from the app's existing
//  intents and walks them through pointing it at their car and wiring it
//  to the CarPlay-disconnect trigger.
//

import SwiftUI

/// iCloud share link for the pre-built "Walk-Away Lock" shortcut
/// (Wait 120s → Refresh Vehicle Status → Is Vehicle Locked → If unlocked,
/// Lock Vehicle). Shared shortcuts can only be authored in the Shortcuts
/// app and distributed by link — there's no API to create one in code.
/// `nil` hides the download button and leads with the build-it-yourself
/// steps instead.
private let walkAwayShortcutURL: URL? = nil // TODO: paste iCloud share link

struct WalkAwayLockGuideView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Walk-Away Lock", systemImage: "car.side.lock")
                        .font(.headline)
                    Text(
                        "Lock your car automatically a couple of minutes after "
                            + "CarPlay disconnects — no GPS or location tracking. "
                            + "iOS only lets apps react to CarPlay through a "
                            + "Shortcuts automation, so setup takes two short steps "
                            + "and works entirely on your phone."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let url = walkAwayShortcutURL {
                Section {
                    Link(destination: url) {
                        Label("Get the Walk-Away Lock Shortcut", systemImage: "square.and.arrow.down")
                            .font(.body.weight(.semibold))
                    }
                } header: {
                    Text("Step 1 — Add the Shortcut")
                } footer: {
                    Text("Opens the Shortcuts app with the pre-built shortcut ready to add.")
                }

                Section {
                    numberedStep(1, "Open the Shortcuts app and tap the new **Walk-Away Lock** shortcut's ⋯ button.")
                    numberedStep(2, "On the **Refresh Vehicle Status** action, tap the Vehicle field and pick your car.")
                    numberedStep(3, "The other actions reuse that result automatically — no further changes needed.")
                } header: {
                    Text("Step 2 — Point it at your car")
                }
            } else {
                Section {
                    numberedStep(1, "Open the **Shortcuts** app and create a new shortcut named **Walk-Away Lock**.")
                    numberedStep(2, "Add a **Wait** action set to **120 seconds** — time to close the doors and walk away.")
                    numberedStep(
                        3,
                        "Add BetterBlue's **Refresh Vehicle Status** action and set its Vehicle to your car. "
                            + "This wakes the car for an up-to-date reading."
                    )
                    numberedStep(
                        4,
                        "Add BetterBlue's **Is Vehicle Locked** action. For its Vehicle, tap the field and "
                            + "choose the **Updated Vehicle** variable from the refresh step."
                    )
                    numberedStep(
                        5,
                        "Add an **If** action on the result: when it **is false**, add BetterBlue's "
                            + "**Lock Vehicle** action (Vehicle → **Updated Vehicle** again). You'll get a "
                            + "notification whenever it sends the lock."
                    )
                } header: {
                    Text("Step 1 — Build the Shortcut")
                } footer: {
                    Text("Already locked? The shortcut does nothing — no redundant commands to your car.")
                }
            }

            Section {
                numberedStep(1, "In Shortcuts, open the **Automation** tab and tap **+**.")
                numberedStep(2, "Choose **CarPlay**, select **Disconnects**, and pick **Run Immediately**.")
                numberedStep(3, "Select the **Walk-Away Lock** shortcut.")
            } header: {
                Text(walkAwayShortcutURL == nil ? "Step 2 — Set up the automation" : "Step 3 — Set up the automation")
            } footer: {
                Text(
                    "That's it — every time your phone disconnects from CarPlay, the shortcut waits "
                        + "two minutes, checks the car, and locks it if it's still unlocked. Adjust the "
                        + "Wait duration in the shortcut anytime."
                )
            }
        }
        .navigationTitle("Walk-Away Lock")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A numbered instruction row; the text renders inline markdown bold.
    private func numberedStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.blue))
            Text(.init(text))
                .font(.callout)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { WalkAwayLockGuideView() }
}
