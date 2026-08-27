//
//  SurroundViewMonitorView.swift
//  BetterBlue
//
//  Surround View Monitor — the 360° camera stills a vehicle takes on
//  request. Two steps sit behind this screen: asking the vehicle to
//  shoot (it wakes its cameras and uploads, which takes minutes), and
//  reading whatever the server is already holding. Opening the screen
//  does the cheap half; the Capture button does the slow half and polls
//  until the new images land.
//

import BetterBlueKit
import SwiftData
import SwiftUI
import UIKit

struct SurroundViewMonitorView: View {
    let bbVehicle: BBVehicle

    @Environment(\.modelContext) private var modelContext

    @State private var captures: [SurroundViewCapture] = []
    @State private var selectedCaptureID: String?
    @State private var selectedPosition: SurroundViewCameraPosition?
    /// Every tile of the selected capture, cropped once when the capture
    /// changes. Rendering up front rather than per tap keeps swiping
    /// between cameras instant — and stops a 4472px-wide composite being
    /// re-decoded on every switch.
    @State private var renderedTiles: [SurroundViewCameraPosition: UIImage] = [:]
    @State private var isLoading = true
    @State private var loadError: ActionError?
    @State private var capturePhase: CapturePhase?
    @State private var captureTask: Task<Void, Never>?

    /// How long to wait for a requested capture before giving up. The
    /// vehicle usually uploads within 1-2 minutes; the extra headroom
    /// covers a modem that takes its time waking up.
    private static let captureTimeout: TimeInterval = 6 * 60
    /// Each poll costs a PIN verification plus the fetch, so keep it
    /// coarse — a capture takes minutes, not seconds.
    private static let pollInterval: TimeInterval = 30

    private enum CapturePhase: Equatable {
        /// Sending the request to the vehicle.
        case requesting(startedAt: Date)
        /// Request accepted; polling for the images.
        case waiting(startedAt: Date)

        var startedAt: Date {
            switch self {
            case .requesting(let date), .waiting(let date): date
            }
        }

        var message: String {
            switch self {
            case .requesting: "Asking the vehicle to take photos…"
            case .waiting: "The vehicle is taking photos and uploading them. This usually takes 1-2 minutes."
            }
        }
    }

    var body: some View {
        PersistentModelGuard(model: bbVehicle) {
            content
                .navigationTitle("Surround View")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        historyMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        shareButton
                    }
                }
                .task {
                    // Only load once — re-entering from a background
                    // shouldn't wipe a capture the user is waiting on.
                    if captures.isEmpty, isLoading {
                        await loadCaptures()
                    }
                }
                .onDisappear {
                    captureTask?.cancel()
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let loadError, captures.isEmpty {
            errorView(loadError)
        } else if captures.isEmpty {
            emptyView
        } else {
            captureView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading surround view…")
                .foregroundColor(.secondary)
        }
    }

    private func errorView(_ error: ActionError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)

            ErrorDetailsView(error: error)
                .padding(.horizontal)

            Button("Try Again") {
                Task { await loadCaptures() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("No Captures Yet")
                .font(.headline)

            Text("Ask the vehicle to take a set of surround-view photos. "
                + "It wakes its cameras, shoots, and uploads them — usually within a few minutes.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            captureControls
        }
        .padding()
    }

    /// Laid out like Photos: the image floats dead centre in whatever
    /// space is left, and the controls sit in a fixed strip along the
    /// bottom of the sheet.
    ///
    /// The cameras don't share an aspect ratio — a fisheye view is
    /// 960x720, the bird's-eye view 632x720 — so anything that sized
    /// itself to the image would shuffle the controls every time you
    /// switched camera. Giving the image the leftover space instead lets
    /// it fill the sheet's full width or full height, whichever it hits
    /// first, while the strip below never moves.
    private var captureView: some View {
        VStack(spacing: 0) {
            imagePager
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlStrip
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    private var controlStrip: some View {
        VStack(spacing: 12) {
            if let loadError {
                ErrorDetailsView(error: loadError)
            }

            captureCaption

            if availablePositions.count > 1 {
                positionPicker
            }

            captureControls
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Image

    /// Swipe between cameras, or use the picker — both drive the same
    /// selection, so they stay in step.
    private var imagePager: some View {
        TabView(selection: Binding(
            get: { resolvedPosition },
            set: { selectedPosition = $0 }
        )) {
            ForEach(availablePositions, id: \.self) { position in
                tileImage(for: position)
                    .tag(position)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func tileImage(for position: SurroundViewCameraPosition) -> some View {
        if let image = renderedTiles[position] {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A tile that failed to decode still leaves the rest of the
            // capture usable, so this is a placeholder, not an error.
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var positionPicker: some View {
        Picker("Camera", selection: Binding(
            get: { resolvedPosition },
            set: { selectedPosition = $0 }
        )) {
            ForEach(availablePositions, id: \.self) { position in
                Text(position.displayName).tag(position)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let displayedImage {
            let shareImage = Image(uiImage: displayedImage)
            ShareLink(item: shareImage, preview: SharePreview(shareTitle, image: shareImage)) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Details

    /// When the capture was taken, plus anything that explains why the
    /// picture above might look wrong.
    ///
    /// Only the folded-mirror note earns a line here. The payload also
    /// reports door and trunk state, but the main vehicle screen already
    /// shows both live and per-door — repeating them from a capture taken
    /// minutes ago would be the same information, staler. Folded mirrors
    /// are different: the side cameras are mounted in the mirrors, so a
    /// folded mirror is the reason the left and right views are aimed at
    /// the pavement.
    @ViewBuilder
    private var captureCaption: some View {
        if let capture = selectedCapture {
            VStack(spacing: 4) {
                Text(capture.capturedAt.map { formatLastUpdated($0) } ?? "Time unknown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if capture.sideMirrorOpen == false {
                    Label("Mirrors folded — side views may be distorted", systemImage: "car.side")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Capture controls

    @ViewBuilder
    private var captureControls: some View {
        if let capturePhase {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(capturePhase.startedAt, style: .timer)
                        .font(.headline)
                        .monospacedDigit()
                }

                Text(capturePhase.message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Stop Waiting", role: .cancel) {
                    captureTask?.cancel()
                    captureTask = nil
                    self.capturePhase = nil
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        } else {
            Button {
                startCapture()
            } label: {
                Label("New Capture", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
        }
    }

    // MARK: - History

    /// Earlier captures live in the toolbar rather than the bottom strip:
    /// the strip is for acting on the picture in front of you, and a
    /// second selector down there competes with the camera picker.
    @ViewBuilder
    private var historyMenu: some View {
        if captures.count > 1 {
            Menu {
                Picker("Capture", selection: Binding(
                    get: { selectedCaptureID ?? captures.first?.id ?? "" },
                    set: { newValue in
                        selectedCaptureID = newValue
                        renderTiles()
                    }
                )) {
                    ForEach(captures) { capture in
                        Text(capture.capturedAt.map { compactLastUpdated($0) } ?? "Unknown")
                            .tag(capture.id)
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: - Derived state

    private var selectedCapture: SurroundViewCapture? {
        guard let selectedCaptureID else { return captures.first }
        return captures.first { $0.id == selectedCaptureID } ?? captures.first
    }

    private var availablePositions: [SurroundViewCameraPosition] {
        selectedCapture?.tiles.map(\.position) ?? []
    }

    /// The camera actually on screen — the user's pick when it still
    /// exists in this capture, otherwise the first one.
    private var resolvedPosition: SurroundViewCameraPosition {
        if let selectedPosition, availablePositions.contains(selectedPosition) {
            return selectedPosition
        }
        return availablePositions.first ?? .composite
    }

    private var displayedImage: UIImage? {
        renderedTiles[resolvedPosition]
    }

    private var shareTitle: String {
        "\(bbVehicle.displayName) — \(resolvedPosition.displayName)"
    }

    // MARK: - Loading

    private func loadCaptures() async {
        isLoading = true
        loadError = nil

        guard let account = bbVehicle.account else {
            loadError = ActionError(
                action: "Load surround view",
                error: APIError(message: "Vehicle account not found")
            )
            isLoading = false
            return
        }

        do {
            apply(try await account.fetchSurroundViewCaptures(for: bbVehicle, modelContext: modelContext))
        } catch {
            BBLogger.error(.api, "SurroundViewMonitorView: Failed to fetch captures: \(error)")
            loadError = ActionError(
                action: "Load surround view",
                error: error,
                accountId: account.id
            )
        }

        isLoading = false
    }

    /// Adopts a freshly fetched list, keeping the user on the capture
    /// they were looking at when it's still present.
    private func apply(_ newCaptures: [SurroundViewCapture], selectingNewest: Bool = false) {
        captures = newCaptures

        if selectingNewest || selectedCaptureID == nil
            || !newCaptures.contains(where: { $0.id == selectedCaptureID }) {
            selectedCaptureID = newCaptures.first?.id
        }

        if let selectedPosition, availablePositions.contains(selectedPosition) {
            // Keep the user's choice.
        } else {
            // The bird's-eye view is the one that answers "what's around
            // my car", so lead with it when the vehicle provides one.
            selectedPosition = availablePositions.contains(.topDown) ? .topDown : availablePositions.first
        }

        renderTiles()
    }

    /// Crops every tile of the selected capture out of its frame.
    ///
    /// Each frame is decoded once and shared by the tiles that live in it
    /// — a surround-view composite is a single 4472px-wide JPEG holding
    /// all five views, so decoding per tile would repeat the expensive
    /// half five times. Done on the main actor: it runs once per capture,
    /// and the alternative is shuttling images across actor boundaries
    /// for no user-visible gain.
    private func renderTiles() {
        guard let capture = selectedCapture else {
            renderedTiles = [:]
            return
        }

        var decodedFrames: [Int: CGImage] = [:]
        var rendered: [SurroundViewCameraPosition: UIImage] = [:]

        for tile in capture.tiles {
            guard let cropped = SurroundViewRendering.image(
                in: capture,
                position: tile.position,
                decodedFrames: &decodedFrames
            ) else {
                continue
            }
            rendered[tile.position] = UIImage(cgImage: cropped)
        }

        renderedTiles = rendered
    }

    // MARK: - Capturing

    private func startCapture() {
        captureTask?.cancel()
        captureTask = Task { await runCapture() }
    }

    private func runCapture() async {
        guard let account = bbVehicle.account else {
            loadError = ActionError(
                action: "New surround view capture",
                error: APIError(message: "Vehicle account not found")
            )
            return
        }

        loadError = nil
        capturePhase = .requesting(startedAt: Date())
        let baseline = captures.first?.capturedAt

        do {
            try await account.requestSurroundViewCapture(for: bbVehicle, modelContext: modelContext)
        } catch {
            BBLogger.error(.api, "SurroundViewMonitorView: Capture request failed: \(error)")
            loadError = ActionError(
                action: "New surround view capture",
                error: error,
                accountId: account.id
            )
            capturePhase = nil
            return
        }

        capturePhase = .waiting(startedAt: Date())
        let deadline = Date().addingTimeInterval(Self.captureTimeout)

        while Date() < deadline {
            do {
                try await Task.sleep(for: .seconds(Self.pollInterval))
            } catch {
                // Cancelled — the user backed out or hit Stop Waiting.
                capturePhase = nil
                return
            }

            if Task.isCancelled {
                capturePhase = nil
                return
            }

            do {
                let latest = try await account.fetchSurroundViewCaptures(for: bbVehicle, modelContext: modelContext)
                if hasNewCapture(in: latest, since: baseline) {
                    apply(latest, selectingNewest: true)
                    capturePhase = nil
                    captureTask = nil
                    return
                }
            } catch {
                // A failed poll isn't fatal — the images may simply not
                // be there yet. Keep waiting and let the deadline decide.
                BBLogger.debug(.api, "SurroundViewMonitorView: Poll failed, still waiting: \(error)")
            }
        }

        capturePhase = nil
        captureTask = nil
        loadError = ActionError(
            action: "New surround view capture",
            error: APIError(
                message: "The vehicle didn't upload new images in time. "
                    + "It may be asleep or out of cellular coverage — try again in a few minutes.",
                apiName: account.brandEnum.displayName
            ),
            accountId: account.id
        )
    }

    private func hasNewCapture(in latest: [SurroundViewCapture], since baseline: Date?) -> Bool {
        guard let newest = latest.first else { return false }
        guard let baseline else { return true }
        guard let capturedAt = newest.capturedAt else {
            // No timestamp to compare — treat a changed identity as new.
            return newest.id != captures.first?.id
        }
        return capturedAt > baseline
    }
}
