//
//  PersistentVehicleSheet.swift
//  BetterBlue
//
//  Apple-Maps-style persistent bottom panel. Unlike a real
//  `.sheet(isPresented:)` it:
//    - Lives inside the tab-content ZStack, so it sits *above* the
//      system tab bar instead of overlaying it.
//    - Doesn't compete with other `.sheet` modifiers — opening
//      Settings (a real sheet) no longer animates this panel away.
//    - Is continuously presented (no dismiss affordance, no
//      `interactiveDismissDisabled` needed — there's no SwiftUI
//      sheet machinery in the loop at all).
//
//  Section order mirrors the legacy VehicleCardView so muscle memory
//  carries over: header (name + refresh) → EV range → charging →
//  gas range → lock → climate → divider → below-the-fold details.
//

import BetterBlueKit
import CoreLocation
import SwiftData
import SwiftUI
import WidgetKit

/// Detent for the persistent vehicle sheet. Two snap heights —
/// shared by both `PersistentVehicleSheet` (which uses it to size
/// its chrome) and `VehicleSheetPager` (which owns the @State so
/// all cards animate together as the user pages between vehicles).
enum SheetDetent { case collapsed, expanded }

/// One self-contained vehicle card. Owns its own glass chrome,
/// drag handle, asymmetric concentric corners, and the actions it
/// hosts. The parent `VehicleSheetPager` just lays a row of these
/// in a paging ScrollView — each card is a complete visual unit,
/// so swiping between them slides whole cards rather than swapping
/// content inside a shared frame.
struct PersistentVehicleSheet: View {
    let bbVehicle: BBVehicle
    let bbVehicles: [BBVehicle]
    /// Index of the currently-visible vehicle in the pager. Used by
    /// the drag handle to render a page-indicator (filled capsule
    /// for selected, small dots for the others) when there's more
    /// than one vehicle. All cards render the same indicator
    /// because they all see the same `selectedIndex`.
    let selectedIndex: Int
    @Binding var detent: SheetDetent
    /// Height of the glass chrome — computed by the parent
    /// `VehicleSheetPager` (so all cards share the same height) and
    /// passed down. The card has no GeometryReader of its own; the
    /// pager handles sizing so it can constrain its outer ScrollView
    /// frame and let map taps pass through above the card.
    let cardHeight: CGFloat
    let onSuccessfulRefresh: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var appSettings = AppSettings.shared
    @Query private var allClimatePresets: [ClimatePreset]

    // Refresh state
    @State private var isRefreshing = false
    @State private var showRefreshSuccess = false

    // Per-action in-progress flags so each circular button can spin
    // independently of the others (locking the vehicle shouldn't stall
    // the climate button's UI).
    @State private var isLockBusy = false
    @State private var isClimateBusy = false
    @State private var isChargingBusy = false
    // Live status text from each in-flight action — replaces the
    // section's idle subtitle so the user sees real progress (e.g.
    // "Locking...", "Waiting for vehicle...", "Charge started").
    // Same mechanism the legacy VehicleButtons used via the
    // statusMessageUpdater closure.
    @State private var lockStatusText: String?
    @State private var chargingStatusText: String?
    @State private var climateStatusText: String?

    // Error state — single banner above the sections, taps to
    // ErrorDetailsSheet for the structured view OR (when the
    // underlying error is `.requiresMFA`) the MFA verify flow.
    @State private var errorMessage: AttributedString?
    @State private var lastActionError: ActionError?
    /// Typed APIError captured alongside `lastActionError` so the
    /// banner tap handler can branch on `.requiresMFA` and route to
    /// the verify flow instead of the generic error details sheet.
    /// Without this, the only way out of a bad-MFA state was to
    /// delete the account and re-add it.
    @State private var lastAPIError: APIError?

    /// MFA flow state — owns the sheet lifecycle for the
    /// verification flow. Driven by `handleMFAError(_:)` when the
    /// user taps an `.requiresMFA` error banner. Hoisted to
    /// MainView so the sheet survives the `scenePhase != .active`
    /// view-tree swap that tears this view down.
    @Bindable var mfaState: MFAFlowState
    /// Shared presentation for every per-vehicle informational
    /// sheet (vehicle info, account info, HTTP logs, climate
    /// settings, etc.). Same hoisting rationale as `mfaState` —
    /// owning state at MainView keeps these sheets presented when
    /// the user briefly backgrounds the app.
    let sheetPresentation: VehicleSheetPresentation

    /// Outer padding on all four sides — the card "floats" inside
    /// this gap. Bottom matches sides so the spacing is uniform.
    private let outerInset: CGFloat = 8
    /// Corner radius for the card's top corners. Picked to be
    /// large enough that the inline refresh button at the trailing
    /// edge of the headerRow visually sits in the corner curve.
    private let cornerRadius: CGFloat = 40
    /// Total vertical space the drag handle occupies inside the
    /// card (8pt top pad + 5pt capsule + 4pt bottom pad). Used to
    /// size the contentArea's bounded frame.
    private let dragHandleHeight: CGFloat = 17
    /// Uniform margin (top + trailing) for the refresh button
    /// overlay. With the button's 20pt radius, this puts the
    /// button center 36pt from each card edge — visually balanced
    /// in the top-trailing corner.
    private let refreshButtonInset: CGFloat = 16

    var body: some View {
        // Guard against a tombstoned model. When the owning account is
        // deleted, SwiftData cascade-deletes its vehicles — but this
        // card can still re-evaluate its body once during the same
        // change transaction, before the pager's ForEach diffs the
        // deleted vehicle out. Reading any persisted property then
        // (e.g. `lockSection` → `bbVehicle.status`) traps in
        // SwiftData's backing store (_InitialBackingData.getValue).
        // `isDeleted` is safe to read on a deleted model; bail to an
        // empty card until the view tree catches up.
        if bbVehicle.isDeleted || bbVehicle.modelContext == nil {
            EmptyView()
        } else {
            cardContent
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        // Page: optional error card above + main card. Both share
        // the same glass-with-ZStack-mask treatment so they look
        // like sibling cards. Error overhead is measured on the
        // error card itself (in `errorCardView`) so the page
        // height doesn't cascade with `cardHeight` during drags.
        VStack(spacing: 8) {
            if let errorMessage {
                errorCardView(errorMessage)
            }
            mainCardBody
        }
        // No card-wide DragGesture — the *vertical* swipe-anywhere
        // behavior is delegated to the inner vertical ScrollView in
        // `contentArea`, which doesn't conflict with the parent
        // horizontal pager because the gestures are perpendicular.
        // We watch its scroll offset and snap the detent when the
        // user scrolls up while collapsed, or overscrolls down past
        // the top while expanded.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
        .ignoresSafeArea(.keyboard)
        // MFA `.mfaFlow(state:)` modifier is attached at MainView
        // (not here) so the sheet survives MainView's `scenePhase
        // != .active` view-tree swap.
        // Per-vehicle sheets (vehicle info, account info, HTTP logs,
        // climate settings, etc.) are attached at MainView via the
        // shared `VehicleSheetPresentation` — so they survive the
        // `scenePhase != .active` view-tree swap. We trigger them
        // by calling `sheetPresentation.show(.someCase(...))`.
        .task(id: bbVehicle.vin) { await refreshStatus() }
    }

    /// Main glass card body. Single, linear pipeline so the
    /// card-to-screen gap is uniform on all four sides by
    /// construction (one trailing `.padding(outerInset)`) and the
    /// glass + clip use the SAME shape sized to the SAME frame —
    /// no separate mask/frame/padding chain to keep in sync.
    ///
    /// Pipeline:
    ///   contentStack
    ///     inner padding (22pt all sides)
    ///     fixed-size measurement (reports natural content height
    ///       to the pager via ContentHeightPreferenceKey)
    ///     bounded to cardHeight (top-anchored — content above the
    ///       clip line stays put when the card shrinks)
    ///     glass background in the rounded shape
    ///     clipShape (clips any content that overflows cardHeight)
    ///     outer 8pt padding (one uniform value → equal gap on all
    ///       four sides)
    @ViewBuilder
    private var mainCardBody: some View {
        let bottomCornerRadius = max(8, DisplayCornerRadius.value - outerInset)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
        contentStack
            // Inner content margin. Horizontal + bottom = 22pt so
            // text sits an even distance from the card edge. Top
            // is only 8pt because the headerRow ZStack stacks the
            // drag handle at y=0 inside contentStack and offsets
            // the title HStack down by 14pt — so the title ends
            // up at 8 + 14 = 22pt from the card edge (matching
            // horizontal), and the drag handle sits visibly near
            // the very top.
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Take the natural height (before the cardHeight clip)
            // and report it up so the pager knows how tall
            // "expanded" should be.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
            // Constrain to the current detent height. Content above
            // the clip line is preserved (top alignment); overflow
            // is removed by the .clipShape below.
            .frame(height: cardHeight, alignment: .top)
            // Glass behind content, in the SAME shape used by clip.
            .background {
                Color.clear.glassEffect(.regular, in: shape)
            }
            // Clip both the glass and any overflowing content to
            // the rounded shape.
            .clipShape(shape)
            // ONE uniform outer padding → equal gap on every side.
            .padding(outerInset)
    }

    /// Error notification card rendered above the main card when
    /// an action fails. Tapping it surfaces the structured error
    /// details sheet (when one exists). Visually styled like a
    /// sibling glass card to the main sheet.
    @ViewBuilder
    private func errorCardView(_ message: AttributedString) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button {
            // requiresMFA gets its own dedicated verification sheet.
            // Without this branch the only way past a stale MFA
            // session was deleting and re-adding the account.
            if let apiError = lastAPIError, apiError.errorType == .requiresMFA {
                handleMFAError(apiError)
            } else if let actionError = lastActionError {
                // Everything else surfaces the structured error
                // details (action + type + collapsible raw response)
                // rather than the full HTTP log dump.
                showErrorDetails(actionError)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Error")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .tint(.blue)
                }
                Spacer()
                // Chevron always shows when we can drill in —
                // either to the MFA verify sheet or the error
                // details sheet.
                if lastAPIError?.errorType == .requiresMFA || lastActionError != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Make the whole card area tap-testable, including the
            // Spacer between text and chevron. Without this only
            // the icon / text / chevron themselves were tappable.
            .contentShape(Rectangle())
            .background(
                ZStack {
                    Color.clear.glassEffect(.regular, in: shape)
                }
                .mask(shape)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, outerInset)
        .padding(.top, outerInset)
        // Report only the error card's own outer height + the
        // VStack spacing — stable measurement that doesn't change
        // with `cardHeight`. Pager adds this to its ScrollView
        // frame so the error card fits above the main card.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ErrorOverheadPreferenceKey.self,
                    value: proxy.size.height + 8
                )
            }
        )
    }

    // MARK: - Chrome (drag handle + content area)

    /// Drag handle that doubles as a pagination indicator. With a
    /// single vehicle it's the familiar 36×5pt capsule. With
    /// multiple vehicles it becomes a row of small dots — one per
    /// vehicle — with the currently-selected dot stretched to a
    /// capsule (e.g. `. _ . .` when on the second of four). All
    /// cards render the same indicator since they all see the
    /// same `selectedIndex` from the pager.
    @ViewBuilder
    private var dragHandle: some View {
        HStack(spacing: 6) {
            if bbVehicles.count <= 1 {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 36, height: 5)
            } else {
                ForEach(0 ..< bbVehicles.count, id: \.self) { index in
                    Capsule()
                        .fill(.tertiary)
                        .frame(
                            width: index == selectedIndex ? 20 : 5,
                            height: 5
                        )
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedIndex)
        // Small internal padding so the capsule sits near the very
        // top of the card. Outer card padding takes care of the
        // breathing room from the actual card edge.
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            detent = detent == .collapsed ? .expanded : .collapsed
        }
        // No local drag gesture — vertical swipe-anywhere is
        // handled by the pager's `verticalCardDragGesture`
        // (attached as a `simultaneousGesture` on the pager's
        // ScrollView) so it works from anywhere on the card.
    }

    // MARK: - Content stack (sections)

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Controls section (header + ranges + lock + climate).
            // Wrapped in its own VStack with a GeometryReader so
            // we can report its height up to the pager — that
            // height becomes the collapsed-detent height, sized
            // exactly to show the controls without the
            // below-the-fold detail rows.
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                // Compact fuel rows for all vehicle types — gas first,
                // then EV (PHEVs get both; pure EV and pure ICE get
                // just the relevant one). EV row's bar upgrades to the
                // thick EVChargingProgressView charging bar when plugged
                // in + charging.
                if let gas = safeGasRange {
                    gasRangeRow(gas)
                }
                if let ev = safeEvStatus {
                    evRangeRow(ev)
                    chargingSection(ev)
                }
                lockSection
                climateSection
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ControlsHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
            Divider().padding(.top, 4)
            detailRows
        }
    }

    // MARK: - Header (ZStack: title + drag handle + refresh button)

    @ViewBuilder
    private var headerRow: some View {
        // ZStack of header elements: title + drag handle +
        // refresh button. The HStack of title+refresh is offset
        // down by the drag handle's height so the handle sits
        // visibly above them at the very top of the row.
        ZStack(alignment: .top) {
            // Title (leading) + refresh button (trailing),
            // offset down by drag handle visual area.
            //
            // `alignment: .top` (not `.center`) so the refresh
            // button's top edge sits exactly at the HStack content
            // top. With `.center`, the taller title VStack (title +
            // "Updated" subtitle = ~52pt) pushes the centered 40pt
            // button down by ~6pt, breaking the uniform top/right
            // margin equation.
            HStack(alignment: .top) {
                Menu {
                    vehicleMenuContent
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(bbVehicle.displayName)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        // Server timestamp moved up here from the
                        // below-the-fold detail rows — when "was it
                        // updated recently?" is the question, having
                        // the answer right under the title beats
                        // making the user scroll. VIN moved to the
                        // detail rows since it's reference info, not
                        // glanceable.
                        if let lastUpdated = bbVehicle.lastUpdated {
                            Text(formatLastUpdated(lastUpdated))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                CircularIconButton(
                    systemName: showRefreshSuccess ? "checkmark" : "arrow.clockwise",
                    tint: showRefreshSuccess ? .green : bbVehicle.primaryColor,
                    isBusy: isRefreshing
                ) {
                    Task { await refreshStatus(forceCacheBypass: true) }
                }
                .disabled(isRefreshing)
            }
            // 14pt of top padding gives 8 (contentStack top) + 14
            // = 22pt total — matches the 22pt horizontal content
            // padding, and the extra 2pt over the drag handle's
            // bottom (drag handle's capsule ends at y=9) gives
            // ~5pt of breathing room between handle and title.
            .padding(.top, 14)
            // Drag handle anchored at the very top of the ZStack.
            dragHandle
        }
    }

    // MARK: - Sections

    /// Compact EV range row. Used for all vehicles with an EV
    /// drivetrain (pure EV + PHEV). Aligns with the SectionRow icon
    /// column (32pt), range left, percentage right, and an
    /// EVChargingProgressView-driven bar — thin capsule when not
    /// charging, thick 32pt charging bar with kW + time + dotted
    /// target SOC line when plugged in and charging.
    @ViewBuilder
    private func evRangeRow(_ ev: VehicleStatus.EVStatus) -> some View {
        let formattedRange: String = {
            guard ev.evRange.range.length > 0 else { return "--" }
            return ev.evRange.range.units.format(
                ev.evRange.range.length,
                to: appSettings.preferredDistanceUnit
            )
        }()
        // Charge speed is hidden on the EV bar — the same value is
        // Speed goes inside the bar (right-aligned, like the widget); the
        // target % is shown by the bar's marker, so the time text is just
        // the duration.
        let chargeSpeed: String? = {
            guard ev.charging, ev.chargeSpeed > 0 else { return nil }
            return String(format: "%.0f kW", ev.chargeSpeed)
        }()
        let timeRemaining: String? = {
            guard ev.charging, ev.chargeTime > .seconds(0) else { return nil }
            return ev.chargeTime.formatted(
                .units(allowed: [.hours, .minutes], width: .abbreviated)
            )
        }()
        // EV indicator color: chargingColor (default green) for both
        // states — user-customizable via Vehicle → Customization →
        // Charging Color.
        let tint = bbVehicle.chargingColor

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: batterySymbol(for: ev.evRange.percentage))
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedRange)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(ev.evRange.percentage))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if ev.charging {
                    EVChargingProgressView(
                        formattedRange: "",
                        batteryPercentage: Int(ev.evRange.percentage),
                        isCharging: true,
                        chargeSpeed: chargeSpeed,
                        chargeTimeRemaining: timeRemaining,
                        targetSOC: ev.currentTargetSOC,
                        showHeader: false,
                        chargingColor: bbVehicle.chargingColor
                    )
                } else {
                    slimProgressBar(
                        percentage: ev.evRange.percentage,
                        tint: tint
                    )
                }
            }
        }
    }

    /// Compact gas range row — same layout as `evRangeRow` but
    /// with a fuelpump icon and a plain slim capsule progress bar.
    /// Used for all vehicles with a gas tank (pure ICE + PHEV).
    @ViewBuilder
    private func gasRangeRow(_ gas: VehicleStatus.FuelRange) -> some View {
        let formattedRange: String = {
            guard gas.range.length > 0 else { return "--" }
            return gas.range.units.format(
                gas.range.length,
                to: appSettings.preferredDistanceUnit
            )
        }()
        // Gas indicator color: gasColor (default orange) —
        // user-customizable via Vehicle → Customization →
        // Gas Color.
        let tint = bbVehicle.gasColor
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "fuelpump.fill")
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedRange)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(gas.percentage))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                slimProgressBar(percentage: gas.percentage, tint: tint)
            }
        }
    }

    /// 6pt capsule progress bar used by both the gas row and the
    /// EV row's not-charging state. Gray background with a tinted
    /// fill. Matches EVChargingProgressView's not-charging bar
    /// thickness exactly.
    @ViewBuilder
    private func slimProgressBar(percentage: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)
                Capsule()
                    .fill(tint.opacity(0.7))
                    .frame(
                        width: geo.size.width * max(0, min(1, percentage / 100.0)),
                        height: 6
                    )
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private func chargingSection(_ ev: VehicleStatus.EVStatus) -> some View {
        let chargingColor = bbVehicle.chargingColor
        let isCharging = ev.charging
        let isPluggedIn = ev.pluggedIn
        // `stop.fill` reads as "tap to stop" unambiguously — the
        // old `bolt.slash.fill` glyph said "no charging" and was
        // easily misread as "charging is unavailable / disabled."
        let icon = isCharging ? "stop.fill" : "bolt.fill"
        let stateText: String = {
            // Just "Charging" — the speed now shows inside the bar.
            if isCharging { return "Charging" }
            if isPluggedIn { return "Ready to Charge" }
            return "Unplugged"
        }()
        // While actively charging, swap the static plug-type glyph
        // for a lightning bolt — reinforces the "energy flowing"
        // cue alongside the icon's pulse animation. Falls back to
        // the brand-specific plug icon when idle / plugged-in.
        let leadingIcon: Image = isCharging
            ? Image(systemName: "bolt.fill")
            : bbVehicle.plugIcon(for: ev.plugType)
        SectionRow(
            icon: leadingIcon,
            iconColor: isPluggedIn ? chargingColor : .secondary,
            // Pulse the status icon (left side) while charging is
            // active — matches the legacy ChargingButton cue. The
            // trailing quick-action button stays static.
            iconAnimation: isCharging ? .pulse : .none,
            // No `title:` — the bolt icon already says "charging,"
            // so the status line ("Ready to Charge" / "Charging at
            // 50 kW" / "Unplugged") stands on its own.
            // While an action is in-flight, show its live status
            // text (e.g. "Starting Charge", "Waiting for vehicle").
            // Falls back to the steady-state stateText when idle.
            subtitle: chargingStatusText ?? stateText,
            menuContent: { chargingMenuContent(isCharging: isCharging) }
        ) {
            // Menu(primaryAction:): tap → toggle, long-press → menu
            // (charge limit settings). Confines the long-press
            // recognizer to the small button area so it doesn't
            // block horizontal swipes on the rest of the row.
            Menu {
                chargingMenuContent(isCharging: isCharging)
            } label: {
                CircularIconLabel(
                    systemName: icon,
                    // Stop state uses the customizable stopColor
                    // (default red) so the button reads as
                    // actionable. Previously used `.secondary`,
                    // which made it look disabled / unresponsive.
                    tint: isCharging
                        ? bbVehicle.stopColor
                        : (isPluggedIn ? chargingColor : .secondary.opacity(0.5)),
                    isBusy: isChargingBusy
                )
            } primaryAction: {
                Task { await toggleCharging(start: !isCharging) }
            }
            // Only disabled when an action is in-flight — NOT when
            // the vehicle reports "unplugged". Server state can lag
            // real-world plug state, so the user should always be
            // able to fire a command if they know their car is
            // actually plugged in.
            .disabled(isChargingBusy)
        }
    }

    @ViewBuilder
    private var lockSection: some View {
        let isLocked = (bbVehicle.lockStatus == .locked)
        SectionRow(
            icon: Image(systemName: isLocked ? "lock.fill" : "lock.open.fill"),
            iconColor: isLocked ? bbVehicle.lockColor : bbVehicle.unlockColor,
            // No `title:` — the lock icon already implies "doors,"
            // so "Locked" / "Unlocked" alone reads cleanly.
            subtitle: lockStatusText ?? (isLocked ? "Locked" : "Unlocked"),
            menuContent: {
                // BOTH actions always available — server state can
                // lag real-world lock state.
                Button {
                    Task { await toggleLock(targetLocked: true) }
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                Button {
                    Task { await toggleLock(targetLocked: false) }
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                }
            }
        ) {
            // Menu(primaryAction:) so long-press surfaces both
            // Lock + Unlock actions (server state can lag, the
            // user might want the opposite action anyway).
            Menu {
                Button {
                    Task { await toggleLock(targetLocked: true) }
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                Button {
                    Task { await toggleLock(targetLocked: false) }
                } label: {
                    Label("Unlock", systemImage: "lock.open.fill")
                }
            } label: {
                CircularIconLabel(
                    systemName: isLocked ? "lock.open.fill" : "lock.fill",
                    tint: isLocked ? bbVehicle.unlockColor : bbVehicle.lockColor,
                    isBusy: isLockBusy
                )
            } primaryAction: {
                Task { await toggleLock(targetLocked: !isLocked) }
            }
            .disabled(isLockBusy)
        }
    }

    @ViewBuilder
    private var climateSection: some View {
        let isClimateOn = bbVehicle.climateStatus?.airControlOn ?? false
        let climateColor = bbVehicle.startClimateColor
        SectionRow(
            icon: Image(systemName: isClimateOn ? "fan" : "fan.slash"),
            iconColor: isClimateOn ? climateColor : .secondary,
            // Spin the fan icon (left side) while climate is running.
            iconAnimation: isClimateOn ? .rotate : .none,
            // No `title:` — the fan icon already says "climate," so
            // the status text ("Off" / "Running at 72°F") is enough.
            subtitle: climateStatusText ?? climateSubtitle,
            menuContent: { climateMenuContent(isClimateOn: isClimateOn) }
        ) {
            // Tap → toggle, long-press → preset shortcuts +
            // Climate Settings.
            Menu {
                climateMenuContent(isClimateOn: isClimateOn)
            } label: {
                CircularIconLabel(
                    // `stop.fill` reads as "tap to stop" — same
                    // reasoning as the charging button (the slash
                    // glyph read as disabled/unavailable).
                    systemName: isClimateOn ? "stop.fill" : "fan",
                    // Stop state uses stopColor (default red) so
                    // the button doesn't look disabled.
                    tint: isClimateOn ? bbVehicle.stopColor : climateColor,
                    isBusy: isClimateBusy
                )
            } primaryAction: {
                Task { await toggleClimate(start: !isClimateOn) }
            }
            .disabled(isClimateBusy)
        }
    }

    private var climateSubtitle: String {
        let isClimateOn = bbVehicle.climateStatus?.airControlOn ?? false
        if isClimateOn, let status = bbVehicle.climateStatus {
            let temp = status.temperature
            if temp.isPlausibleForDisplay {
                let formatted = temp.units.format(temp.value, to: appSettings.preferredTemperatureUnit)
                return "Running at \(formatted)"
            }
            return "Running"
        }
        return "Off"
    }

    // MARK: - Below-the-fold detail rows

    @ViewBuilder
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let syncDate = bbVehicle.syncDate {
                DetailRow(
                    icon: "car",
                    label: "Car Timestamp",
                    value: formatLastUpdated(syncDate)
                )
            }
            DetailRow(
                icon: "number",
                label: "VIN",
                value: bbVehicle.vin
            )
            DetailRow(
                icon: "speedometer",
                label: "Odometer",
                value: bbVehicle.odometer.units.format(
                    bbVehicle.odometer.length,
                    to: appSettings.preferredDistanceUnit
                )
            )
            if let battery12V = bbVehicle.battery12V {
                DetailRow(
                    icon: "batteryblock",
                    label: "12V Battery",
                    value: "\(battery12V)%",
                    valueColor: battery12V < 30 ? .red : (battery12V < 50 ? .orange : .primary)
                )
            }
            if let doorOpen = bbVehicle.doorOpen {
                let doorStatus = doorStatusText(doorOpen: doorOpen)
                DetailRow(
                    icon: doorOpen.anyOpen ? "exclamationmark.triangle" : "lock",
                    label: "Doors",
                    value: doorStatus.text,
                    valueColor: doorStatus.isOpen ? .orange : .green
                )
            }
            let hood = bbVehicle.hoodOpen ?? false
            let trunk = bbVehicle.trunkOpen ?? false
            DetailRow(
                icon: hood || trunk ? "exclamationmark.triangle" : "car.side",
                label: "Hood / Trunk",
                value: hoodTrunkText(hood: hood, trunk: trunk),
                valueColor: (hood || trunk) ? .orange : .green
            )
            if let tirePressure = bbVehicle.tirePressureWarning {
                DetailRow(
                    icon: tirePressure.hasWarning ? "exclamationmark.tirepressure" : "tirepressure",
                    label: "Tire Pressure",
                    value: tirePressureText(tirePressure),
                    valueColor: tirePressure.hasWarning ? .orange : .green
                )
            }
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private func errorBanner(_ message: AttributedString) -> some View {
        Button {
            if let actionError = lastActionError {
                showErrorDetails(actionError)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .tint(.blue)
                Spacer()
                if lastActionError != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Vehicle name menu content

    @ViewBuilder
    private var vehicleMenuContent: some View {
        if let location = safeLocation {
            let availableApps = NavigationHelper.availableMapApps
            let coordinate = CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            )
            let destinationName = bbVehicle.displayName
            if availableApps.count == 1 {
                Button {
                    NavigationHelper.navigate(
                        using: availableApps[0],
                        to: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            } else {
                Menu {
                    NavigationMenuContent(
                        coordinate: coordinate,
                        destinationName: destinationName
                    )
                } label: {
                    Label("Navigate to Vehicle", systemImage: "location")
                }
            }
        }

        if bbVehicle.fuelType.hasElectricCapability,
           bbVehicle.account?.supportsEVTripDetails == true {
            Button {
                sheetPresentation.show(.tripDetails(vehicle: bbVehicle))
            } label: {
                Label("Trip History", systemImage: "chart.line.uptrend.xyaxis")
            }
        }

        Button {
            sheetPresentation.show(.vehicleInfo(vehicle: bbVehicle))
        } label: {
            Label("Vehicle Info", systemImage: "car.fill")
        }

        if let account = bbVehicle.account {
            Button {
                sheetPresentation.show(.accountInfo(account: account))
            } label: {
                Label("Account Info", systemImage: "person.circle")
            }

            if AppSettings.shared.debugModeEnabled {
                Button {
                    sheetPresentation.show(.httpLogs(account: account))
                } label: {
                    Label("HTTP Logs", systemImage: "network")
                }
            }

            if account.brandEnum == .fake {
                Button {
                    sheetPresentation.show(.vehicleConfiguration(vehicle: bbVehicle))
                } label: {
                    Label("Configure Vehicle", systemImage: "gearshape.fill")
                }
            }
        }
    }

    // MARK: - Action menus (long-press on section circular button)

    @ViewBuilder
    private func chargingMenuContent(isCharging: Bool) -> some View {
        // BOTH actions always available — server state can lag
        // real-world charging state, so the user should always be
        // able to fire either command.
        Button {
            Task { await toggleCharging(start: true) }
        } label: {
            Label("Start Charge", systemImage: "bolt.fill")
        }
        Button {
            Task { await toggleCharging(start: false) }
        } label: {
            Label("Stop Charge", systemImage: "bolt.slash")
        }
        Button {
            sheetPresentation.show(.chargeLimitSettings(vehicle: bbVehicle))
        } label: {
            Label("Charge Limits", systemImage: "battery.100percent")
        }
    }

    @ViewBuilder
    private func climateMenuContent(isClimateOn: Bool) -> some View {
        // BOTH actions always available — server state can lag
        // real-world climate state.
        Button {
            Task { await toggleClimate(start: true) }
        } label: {
            Label("Start Climate", systemImage: "fan")
        }
        Button {
            Task { await toggleClimate(start: false) }
        } label: {
            Label("Stop Climate", systemImage: "fan.slash")
        }
        // Preset shortcuts (only the non-selected ones — selected is the
        // default behavior of the main tap).
        ForEach(filteredClimatePresets.filter { !$0.isSelected }, id: \.id) { preset in
            let options = preset.climateOptions
            Button {
                Task { await toggleClimate(start: true, options: options) }
            } label: {
                Label("Start \(preset.name)", systemImage: preset.iconName)
            }
        }
        Button {
            sheetPresentation.show(.climateSettings(vehicle: bbVehicle))
        } label: {
            Label("Climate Settings", systemImage: "gearshape.fill")
        }
    }

    private var filteredClimatePresets: [ClimatePreset] {
        allClimatePresets.filter { $0.vehicle?.id == bbVehicle.id }
    }

    private var selectedClimatePreset: ClimatePreset? {
        filteredClimatePresets.first { $0.isSelected }
            ?? filteredClimatePresets.first
    }

    // MARK: - Safe accessors

    private var safeEvStatus: VehicleStatus.EVStatus? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.evStatus
    }

    private var safeGasRange: VehicleStatus.FuelRange? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.gasRange
    }

    private var safeLocation: VehicleStatus.Location? {
        guard bbVehicle.modelContext != nil else { return nil }
        return bbVehicle.location
    }

    // MARK: - Refresh action

    private func refreshStatus(forceCacheBypass: Bool = false) async {
        await MainActor.run {
            isRefreshing = true
            showRefreshSuccess = false
            errorMessage = nil
            lastActionError = nil
            lastAPIError = nil
        }
        do {
            guard let account = bbVehicle.account else {
                throw APIError(message: "Account not found for vehicle")
            }
            try await account.fetchAndUpdateVehicleStatus(
                for: bbVehicle,
                modelContext: modelContext,
                cached: !forceCacheBypass,
                forceVehicleListRefresh: forceCacheBypass
            )
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = true
                WidgetCenter.shared.reloadAllTimelines()
                onSuccessfulRefresh?()
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { showRefreshSuccess = false }
                }
            }
        } catch {
            await MainActor.run {
                isRefreshing = false
                showRefreshSuccess = false
                guard !(error is CancellationError) else { return }
                handleError(error, action: "Refresh \(bbVehicle.displayName)")
            }
        }
    }

    // MARK: - Lock / unlock action

    @MainActor
    private func toggleLock(targetLocked: Bool) async {
        guard let account = bbVehicle.account else { return }
        isLockBusy = true
        lockStatusText = targetLocked ? "Locking" : "Unlocking"
        defer {
            isLockBusy = false
            lockStatusText = nil
        }
        let context = modelContext
        do {
            if targetLocked {
                try await account.lockVehicle(bbVehicle, modelContext: context)
            } else {
                try await account.unlockVehicle(bbVehicle, modelContext: context)
            }
            let target: VehicleStatus.LockStatus = targetLocked ? .locked : .unlocked
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.lockStatus == target },
                statusMessageUpdater: { msg in
                    Task { @MainActor in lockStatusText = msg }
                }
            )
        } catch {
            handleError(error, action: targetLocked ? "Lock \(bbVehicle.displayName)" : "Unlock \(bbVehicle.displayName)")
        }
    }

    // MARK: - Charging start / stop action

    @MainActor
    private func toggleCharging(start: Bool) async {
        guard let account = bbVehicle.account else { return }
        isChargingBusy = true
        chargingStatusText = start ? "Starting Charge" : "Stopping Charge"
        defer {
            isChargingBusy = false
            chargingStatusText = nil
        }
        let context = modelContext
        do {
            if start {
                try await account.startCharge(bbVehicle, modelContext: context)
            } else {
                try await account.stopCharge(bbVehicle, modelContext: context)
                // Mirror legacy ChargingButton: poke status immediately
                // so Live Activity ends even if the wait below times out.
                try? await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle, modelContext: context, cached: false
                )
            }
            // Charging state propagates slowest through the backends —
            // give it a longer window (matches ChargingButton).
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.evStatus?.charging == start },
                statusMessageUpdater: { msg in
                    Task { @MainActor in chargingStatusText = msg }
                },
                maxAttempts: 5,
                retryDelaySeconds: 15
            )
        } catch {
            handleError(error, action: start ? "Start Charging \(bbVehicle.displayName)" : "Stop Charging \(bbVehicle.displayName)")
        }
    }

    // MARK: - Climate start / stop action

    @MainActor
    private func toggleClimate(start: Bool, options: ClimateOptions? = nil) async {
        guard let account = bbVehicle.account else { return }
        isClimateBusy = true
        climateStatusText = start ? "Starting Climate" : "Stopping Climate"
        defer {
            isClimateBusy = false
            climateStatusText = nil
        }
        let context = modelContext
        let preset = selectedClimatePreset
        do {
            if start {
                let climateOptions = options ?? preset?.climateOptions
                    ?? ClimateOptions(preferredUnits: appSettings.preferredTemperatureUnit)
                try await account.startClimate(
                    bbVehicle,
                    options: climateOptions,
                    modelContext: context,
                    presetName: preset?.name,
                    presetIcon: preset?.iconName
                )
            } else {
                try await account.stopClimate(bbVehicle, modelContext: context)
                try? await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle, modelContext: context, cached: false
                )
            }
            try await bbVehicle.waitForStatusChange(
                modelContext: context,
                condition: { $0.climateStatus.airControlOn == start },
                statusMessageUpdater: { msg in
                    Task { @MainActor in climateStatusText = msg }
                }
            )
        } catch {
            handleError(error, action: start ? "Start Climate \(bbVehicle.displayName)" : "Stop Climate \(bbVehicle.displayName)")
        }
    }

    // MARK: - Error wiring

    private func handleError(_ error: Error, action: String) {
        // Verification timeout is NOT a failure — the command was accepted
        // and usually completes; the backend just hasn't reflected it yet
        // (issue #83). No red banner: the next status refresh settles it.
        if let apiError = error as? APIError, apiError.errorType == .statusVerificationTimeout {
            BBLogger.info(.app, "\(action): command sent, confirmation pending")
            return
        }
        let message: String
        if let apiError = error as? APIError {
            // Route through the friendly-message mapping so the
            // banner reads as user-actionable text — most
            // importantly so the `.requiresMFA` case ends with
            // "Tap to verify," which is the only hint the user
            // gets that the banner is interactive.
            message = friendlyMessage(for: apiError, action: action)
            lastAPIError = apiError
        } else {
            message = "\(action) failed: \(error.localizedDescription)"
            lastAPIError = nil
        }
        if let attributed = try? AttributedString(markdown: message) {
            errorMessage = attributed
        } else {
            errorMessage = AttributedString(message)
        }
        // MFA gets its own dedicated flow — skip the generic
        // error-details sheet so dismissing the MFA verify view
        // doesn't leave a stale `ActionError` pointer that would
        // route the next banner tap to the wrong sheet.
        if let apiError = error as? APIError, apiError.errorType == .requiresMFA {
            lastActionError = nil
        } else {
            lastActionError = ActionError(
                action: action,
                error: error,
                accountId: bbVehicle.account?.id
            )
        }
    }

    /// Map an APIError to the friendly banner text. Mirrors the
    /// legacy `VehicleCardView.getUserFriendlyErrorMessage(for:)`
    /// so the redesign keeps the same messaging users are used to.
    private func friendlyMessage(for error: APIError, action: String) -> String {
        switch error.errorType {
        case .invalidCredentials:
            return "Login expired — please check account settings"
        case .invalidPin:
            return "PIN validation failed — check account settings"
        case .invalidVehicleSession:
            return "Vehicle session expired — trying to reconnect"
        case .serverError:
            return "Server temporarily unavailable — try again later"
        case .concurrentRequest:
            return "Another request in progress — please wait and try again"
        case .failedRetryLogin:
            return "Unable to reconnect — check account settings"
        case .requiresMFA:
            // Echoes the server-side context ("Session expired",
            // "MFA Required", etc.) and tells the user the banner
            // is tappable.
            return "\(error.message) — Tap to verify"
        case .general:
            return friendlyGeneralMessage(for: error, action: action)
        case .kiaInvalidRequest:
            return error.message
        case .regionNotSupported:
            return "This region is not yet supported"
        case .statusVerificationTimeout:
            // Normally unreachable — handleError early-returns for this
            // type (soft state, no banner) — but keep a sane message in
            // case another path routes it here.
            return "Command sent — the vehicle hasn't confirmed the change yet"
        }
    }

    private func friendlyGeneralMessage(for error: APIError, action: String) -> String {
        if error.message.contains("timeout") || error.message.contains("timed out") {
            return "Vehicle not responding — try again later"
        }
        if error.message.lowercased().contains("network") {
            return "Network connection issue — check your internet"
        }
        if error.message.contains("404") {
            return "Vehicle not found on server"
        }
        if error.message.contains("500") || error.message.contains("502") || error.message.contains("503") {
            return "Server temporarily unavailable — try again later"
        }
        if let code = error.code, code >= 400 {
            return "Server error (\(code)) — try again later"
        }
        return "\(action) failed — check connection and try again"
    }

    /// Open the MFA verification sheet for the captured APIError.
    /// On success, clear all error state and refresh status so the
    /// banner goes away and the sheet shows fresh data.
    private func handleMFAError(_ error: APIError) {
        guard let account = bbVehicle.account else { return }
        mfaState.start(from: error, account: account) {
            await MainActor.run {
                errorMessage = nil
                lastAPIError = nil
                lastActionError = nil
            }
            await refreshStatus()
        }
    }

    /// Surface the structured error details sheet via the shared
    /// presentation. The `onClear` closure captures `self` so it
    /// can wipe the originating view's banner state when the user
    /// taps "Clear Error" — if the view has been remounted by the
    /// time that happens (e.g. scenePhase swap), the closure
    /// silently no-ops, which is fine because the new view starts
    /// with no banner state anyway.
    private func showErrorDetails(_ error: ActionError) {
        sheetPresentation.show(.errorDetails(error: error) {
            errorMessage = nil
            lastActionError = nil
            lastAPIError = nil
        })
    }

    // MARK: - Formatters

    private func formatRange(_ range: VehicleStatus.FuelRange) -> String {
        range.range.units.format(range.range.length, to: appSettings.preferredDistanceUnit)
    }

    /// SF Symbol name for the EV row's battery icon. SF Symbols
    /// only ships battery icons at the 0/25/50/75/100 stops, so
    /// we pick the closest bucket to the actual percentage.
    private func batterySymbol(for percentage: Double) -> String {
        switch percentage {
        case ..<12.5:  return "battery.0percent"
        case ..<37.5:  return "battery.25percent"
        case ..<62.5:  return "battery.50percent"
        case ..<87.5:  return "battery.75percent"
        default:       return "battery.100percent"
        }
    }

    private func chargingDetailText(_ ev: VehicleStatus.EVStatus) -> String? {
        var bits: [String] = []
        if ev.chargeSpeed > 0 {
            bits.append(String(format: "%.1f kW", ev.chargeSpeed))
        }
        let duration = ev.chargeTime
        if duration > .seconds(0) {
            let formatted = duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            if let target = ev.currentTargetSOC {
                bits.append("\(formatted) to \(Int(target))%")
            } else {
                bits.append(formatted)
            }
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func doorStatusText(doorOpen: VehicleStatus.DoorStatus) -> (text: String, isOpen: Bool) {
        let entries: [(String, Bool)] = [
            ("Front Left", doorOpen.frontLeft),
            ("Front Right", doorOpen.frontRight),
            ("Rear Left", doorOpen.backLeft),
            ("Rear Right", doorOpen.backRight)
        ]
        let openCount = entries.filter { $0.1 }.count
        if openCount == 0 { return ("Closed", false) }
        if openCount == 1, let open = entries.first(where: { $0.1 }) {
            return ("\(open.0) open", true)
        }
        return ("\(openCount) open", true)
    }

    private func hoodTrunkText(hood: Bool, trunk: Bool) -> String {
        switch (hood, trunk) {
        case (true, true): return "Hood & Trunk open"
        case (true, false): return "Hood open"
        case (false, true): return "Trunk open"
        case (false, false): return "Closed"
        }
    }

    private func tirePressureText(_ pressure: VehicleStatus.TirePressureWarning) -> String {
        if !pressure.hasWarning { return "OK" }
        if pressure.all { return "All tires low" }
        let entries: [(String, Bool)] = [
            ("Front Left", pressure.frontLeft),
            ("Front Right", pressure.frontRight),
            ("Rear Left", pressure.rearLeft),
            ("Rear Right", pressure.rearRight)
        ]
        let lowCount = entries.filter { $0.1 }.count
        if lowCount == 1, let low = entries.first(where: { $0.1 }) {
            return "\(low.0) low"
        }
        return "\(lowCount) tires low"
    }
}

// MARK: - Section row helper

/// Single horizontal row used by lock / climate / charging sections.
/// Left: status icon + title above subtitle (wrapped in a `Menu` so
/// tapping the label area opens the same options as long-pressing
/// the trailing quick-action button). Right: caller-supplied
/// trailing content (the circular action button).
///
/// The leading-area Menu is a tap-to-show Menu (not a contextMenu),
/// so it doesn't add a competing long-press recognizer to the row
/// — horizontal-swipe paging continues to work.
private struct SectionRow<Trailing: View, MenuContent: View>: View {
    let icon: Image
    let iconColor: Color
    var iconAnimation: AnimatedStatusIcon.Animation = .none
    /// Optional header label ("Charging", "Doors", "Climate"). When
    /// nil, the row collapses to a single prominent status line —
    /// useful for the action rows where the title was redundant
    /// with the icon and the status text alone communicates the
    /// state ("Ready to Charge" / "Locked" / "Off" already imply
    /// which section they belong to).
    var title: String?
    let subtitle: String
    @ViewBuilder var menuContent: () -> MenuContent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Menu {
                menuContent()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    AnimatedStatusIcon(
                        icon: icon,
                        color: iconColor,
                        animation: iconAnimation
                    )
                    .frame(width: 32, height: 32)
                    if let title {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        // No header — promote the status text to the
                        // title's font weight so the row still has
                        // visual heft alongside the icon and trailing
                        // button.
                        Text(subtitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
    }
}

// MARK: - Animated status icon

/// Renders an Image with an optional continuous pulse (scale) or
/// rotate (360° spin) animation. Used by `SectionRow` to communicate
/// "this thing is currently active" — pulse while charging, rotate
/// while the climate fan is running.
struct AnimatedStatusIcon: View {
    enum Animation { case none, pulse, rotate }

    let icon: Image
    let color: Color
    var animation: Animation = .none

    @State private var phase: Double = 0

    var body: some View {
        let base = icon
            .font(.title3)
            .foregroundStyle(color)
        Group {
            switch animation {
            case .none:
                base
            case .pulse:
                base.scaleEffect(1.0 + 0.18 * phase)
            case .rotate:
                base.rotationEffect(.degrees(360 * phase))
            }
        }
        .onAppear { startAnimation() }
        .onChange(of: animation) { _, _ in startAnimation() }
    }

    private func startAnimation() {
        phase = 0
        switch animation {
        case .none:
            return
        case .pulse:
            withAnimation(
                SwiftUI.Animation.easeInOut(duration: 0.9)
                    .repeatForever(autoreverses: true)
            ) {
                phase = 1
            }
        case .rotate:
            withAnimation(
                SwiftUI.Animation.linear(duration: 2.0)
                    .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}

// MARK: - Detail row (below-the-fold)

private struct DetailRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Circular icon button

/// Just the visual — circle background, optional spinner or icon.
/// Used as the label for both `Button` (refresh / lock) and
/// `Menu(primaryAction:)` (charging / climate, where long-press
/// surfaces extras like presets and charge limits).
struct CircularIconLabel: View {
    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            Group {
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: diameter * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Convenience Button wrapper around `CircularIconLabel` for cases
/// without a long-press menu (refresh, lock).
struct CircularIconButton: View {
    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircularIconLabel(
                systemName: systemName,
                tint: tint,
                isBusy: isBusy,
                diameter: diameter
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content-height preference key

/// PreferenceKey used by each `PersistentVehicleSheet` to report its
/// natural (unconstrained) MAIN-card content height back up to its
/// parent `VehicleSheetPager`. Drives the main card's `cardHeight`
/// detent calc — independent of the error card overhead.
private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Measures the height of just the controls section (everything
/// above the divider — header, ranges, lock, climate). The pager
/// uses this per-vehicle value as the collapsed detent height, so
/// the collapsed sheet shows exactly the controls with no padding
/// of dead space. Different fuel types report different heights
/// (an EV has the charging row, a PHEV has both EV + gas rows,
/// etc.), so each vehicle gets its own measurement.
private struct ControlsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey reporting the height contribution of the optional
/// error card above the main card (its outer height + the VStack
/// spacing). The pager adds the max across all cards to its
/// `scrollViewHeight` so the error card fits without being clipped.
/// Reports 0 when no error is present.
///
/// Crucially, this measures ONLY the error card itself — NOT the
/// total page including the main card. The main card's height
/// changes every frame during a drag, so measuring the whole page
/// would cascade `cardHeight` → measurement → `scrollViewHeight` →
/// re-layout per drag tick, producing visible judder. Measuring
/// just the (drag-independent) error overhead breaks that loop.
private struct ErrorOverheadPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Vehicle sheet pager

/// Horizontal paging container for one `PersistentVehicleSheet` per
/// vehicle. Owns the shared detent + drag-translation state so all
/// cards animate to the same height together, and computes the
/// card height from the largest natural content height reported by
/// any card.
///
/// The pager bounds its ScrollView's frame to the current card
/// height and bottom-anchors it inside an outer VStack — so the
/// ScrollView only intercepts touches in the actual card area and
/// touches above pass through to the map underneath.
struct VehicleSheetPager: View {
    let bbVehicles: [BBVehicle]
    @Binding var selectedVehicleIndex: Int
    let onSuccessfulRefresh: (() -> Void)?
    /// MFA flow state hoisted from MainView. Passed through to each
    /// `PersistentVehicleSheet` so all cards share the same
    /// instance — there's only ever one MFA flow active at a time,
    /// and keeping it MainView-owned means the sheet survives the
    /// scenePhase view-tree swap.
    let mfaState: MFAFlowState
    /// Same hoisting rationale — shared presentation for all
    /// per-vehicle sheets.
    let sheetPresentation: VehicleSheetPresentation

    /// Per-VIN detent state — each vehicle remembers whether the
    /// user left its sheet collapsed or expanded. Swiping to a
    /// different vehicle no longer resets the detent; come back
    /// and it's where you left it.
    @State private var detents: [String: SheetDetent] = [:]

    private var currentVin: String? {
        selectedVehicleIndex < bbVehicles.count
            ? bbVehicles[selectedVehicleIndex].vin
            : nil
    }

    private func detent(for vin: String) -> SheetDetent {
        detents[vin] ?? .collapsed
    }

    /// Binding handed to each card so its drag handle tap and any
    /// other detent writes land in the per-vehicle slot rather
    /// than a single shared value.
    private func detentBinding(for vin: String) -> Binding<SheetDetent> {
        Binding(
            get: { detents[vin] ?? .collapsed },
            set: { detents[vin] = $0 }
        )
    }
    /// Live vertical drag offset from the pager's swipe gesture.
    /// Positive = finger dragged down (shrink), negative = up (grow).
    @State private var dragTranslation: CGFloat = 0
    /// Captures the `translation.height` at the moment the gesture
    /// commits to vertical. Subsequent updates use the delta from
    /// this offset, so `dragTranslation` starts at 0 (no jump from
    /// the gesture's `minimumDistance` deadzone).
    @State private var dragActivationOffset: CGFloat?
    /// True from the moment the vertical drag commits (gesture
    /// activation) until the finger lifts. While true, the pager's
    /// horizontal scroll is disabled — otherwise the ScrollView
    /// can be left stuck between pages when the user transitions
    /// from a horizontal pan into a vertical resize mid-gesture.
    @State private var verticalDragActive = false
    /// Bumped on every vertical-drag-end. The pager's ScrollViewReader
    /// watches this and re-snaps to `selectedVehicleIndex` so we
    /// recover from any partial horizontal offset that slipped in
    /// before the vertical gesture took over.
    @State private var pagerResnapTrigger = 0
    /// Per-VIN natural content height. Pager uses `max` across all
    /// reported values so cards render at a consistent height,
    /// preventing height jumps during paging.
    @State private var naturalHeights: [String: CGFloat] = [:]
    /// Per-VIN error-card overhead (errorCardView outer height + 8pt
    /// VStack spacing). Stable measurement — doesn't change with
    /// `cardHeight` during drags. Pager adds the max across cards
    /// to `scrollViewHeight` so the error card fits above the main
    /// card without clipping.
    @State private var errorOverheads: [String: CGFloat] = [:]
    /// Per-VIN controls-section height (header + ranges + lock +
    /// climate, measured by `ControlsHeightPreferenceKey`). Used
    /// as the collapsed-detent height for THAT specific vehicle —
    /// per-fuel-type, so an ICE car (no charging row) collapses
    /// to a shorter card than a PHEV (gas + EV + charging).
    @State private var controlsHeights: [String: CGFloat] = [:]

    /// Floor for the collapsed detent — used until the per-vehicle
    /// `controlsHeights` measurement arrives on first render so
    /// the card doesn't briefly flash at 0 height.
    private let collapsedHeightFloor: CGFloat = 200
    /// `controlsHeight` is measured on the inner controls VStack
    /// only — it does NOT include the contentStack's outer
    /// `.padding(.top, 8)` + `.padding(.bottom, 22)`. We add those
    /// 30pt back here so the collapsed card actually FITS the
    /// controls (previously cut off the bottom row).
    private let contentVerticalPadding: CGFloat = 8 + 22
    /// Buffer added to the expanded detent so the bottom of the
    /// detail rows sits a comfortable distance from the rounded
    /// card edge instead of crowding it.
    private let expandedBuffer: CGFloat = 24
    private let expandedTopInset: CGFloat = 80
    private let snapThreshold: CGFloat = 60
    /// Extra space the main card adds on top of `cardHeight` for
    /// its outer chrome — 8pt of `outerInset` padding on both the
    /// top and the bottom of `mainCardBody`. Must equal the SUM of
    /// both, otherwise the ScrollView frame clips one of them and
    /// the visible outer margin reads as smaller on that side.
    private let chromeOuterInset: CGFloat = 16


    var body: some View {
        GeometryReader { geo in
            // Each card now computes its OWN height (per VIN), so the
            // user sees the new card at its correct height during the
            // swipe rather than getting a snap when the swipe settles.
            // The ScrollView frame itself uses the MAX height across
            // all vehicles so the tallest can fit; shorter cards sit
            // bottom-aligned within that frame (HStack alignment:
            // .bottom). Map taps in the dead area above a short card
            // are eaten by the ScrollView — acceptable trade-off
            // versus the post-swipe height jump it replaces.
            // Size the shared scroll view to the tallest SINGLE card —
            // its own height plus its own error banner — rather than the
            // max card height plus the max error overhead taken
            // independently across vehicles. Maxing the two components
            // separately over-reserves height whenever the tallest card
            // and the card showing an error banner are *different*
            // vehicles; that surplus then sits as empty space under every
            // (top-aligned, bottom-pinned) card, floating the whole sheet
            // up off the bottom of the screen.
            let scrollViewHeight = (bbVehicles
                .map { cardHeight(for: $0.vin, geo: geo) + (errorOverheads[$0.vin] ?? 0) }
                .max() ?? 0) + chromeOuterInset
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                pagerScrollView(geo: geo)
                    .frame(height: scrollViewHeight)
                    // Vertical swipe-anywhere — attached as a
                    // `simultaneousGesture` on the pager's ScrollView.
                    // Direction-dominance check in the gesture keeps
                    // it from firing on horizontal pans so the
                    // pager's paging snap stays clean.
                    .simultaneousGesture(verticalCardDragGesture)
                    // Animate when the current vehicle's detent flips
                    // (the user pulled / tapped the handle / drag
                    // gesture settled). Keyed on the dictionary so any
                    // per-VIN change re-runs the animation.
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detents)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: maxNaturalHeight)
                    // No animation when `selectedVehicleIndex`
                    // changes — when the user swipes to a card with
                    // a different fuel type, the card height should
                    // just BE the right size on the new render, not
                    // spring-animate into place after the swipe
                    // settles (which reads as a distracting
                    // post-swipe bounce).
                    .animation(nil, value: selectedVehicleIndex)
                    // No `.animation(nil, value: dragTranslation)` —
                    // the live-drag updates already use a
                    // disablesAnimations transaction in `onChanged`,
                    // and we *want* the spring-back from rubber-
                    // band overdrag (set via `withAnimation` in
                    // `onEnded`) to animate naturally.
            }
        }
        // Extend through the bottom safe area so the card's outer
        // edge sits the same 8pt off the physical screen on ALL
        // four sides. Respecting the safe area instead leaves the
        // ~34pt home-indicator strip below the card, which makes
        // the *outer* bottom gap (card → screen edge) read as much
        // larger than the left/right gap. This is the gap the user
        // measures visually, so it has to match.
        .ignoresSafeArea(edges: .bottom)
    }

    private var maxNaturalHeight: CGFloat {
        naturalHeights.values.max() ?? 0
    }

    /// Per-vehicle card height — driven by THAT vehicle's own
    /// controls/natural measurements so each card slides into view
    /// at the correct height during a swipe, not at whatever the
    /// previous card was.
    private func cardHeight(for vin: String, geo: GeometryProxy) -> CGFloat {
        // `geo.size.height` can be 0 (or briefly tiny) on first
        // GeometryReader pass before layout completes. Without the
        // `max(0, ...)` clamp, `screenMax` goes negative, which
        // propagates through `expanded`/`base`/`resolved` and ends
        // up as a negative `.frame(height:)`, producing the
        // "Invalid frame dimension (negative or non-finite)"
        // runtime warnings.
        let screenMax = max(0, geo.size.height - expandedTopInset)

        let perVehicleControls = controlsHeights[vin] ?? 0
        let perVehicleNatural = naturalHeights[vin] ?? 0
        // Collapsed = controls VStack + the contentStack's outer
        // vertical padding (which the measurement doesn't include).
        // Floor protects against the first render before measurement.
        let collapsed = max(
            collapsedHeightFloor,
            perVehicleControls > 0 ? perVehicleControls + contentVerticalPadding : 0
        )
        // Expanded = full content (already includes its own padding,
        // since ContentHeightPreferenceKey measures the outer padded
        // chain) + a small breathing buffer.
        let naturalWithBuffer = perVehicleNatural > 0
            ? perVehicleNatural + expandedBuffer
            : 0

        let expanded: CGFloat = naturalWithBuffer > 0
            ? min(naturalWithBuffer, screenMax)
            : screenMax
        // Each card respects ITS OWN detent — swiping between
        // vehicles preserves whatever expanded/collapsed state the
        // user left them in.
        let cardDetent = detent(for: vin)
        let base = cardDetent == .collapsed ? min(collapsed, expanded) : expanded
        // dragTranslation < 0 grows the card, > 0 shrinks it.
        let unclamped = base - dragTranslation

        // Bounds for the natural drag range — beyond these we
        // apply rubber-band damping so the card resists the pull.
        let minBound = min(collapsed, expanded)
        let maxBound = expanded

        let resolved: CGFloat
        if unclamped > maxBound {
            // Over-pull past max (growing past expanded): rubber-
            // band damping with diminishing returns.
            // `(overshoot * cap) / (overshoot + cap)` asymptotically
            // approaches `cap` as overshoot grows — same formula
            // UIScrollView uses for bounce.
            let overshoot = unclamped - maxBound
            let cap: CGFloat = 80
            let damped = (overshoot * cap) / (overshoot + cap)
            resolved = maxBound + damped
        } else if unclamped < minBound {
            // Over-pull past min (shrinking past collapsed):
            // same damping in the opposite direction.
            let undershoot = minBound - unclamped
            let cap: CGFloat = 80
            let damped = (undershoot * cap) / (undershoot + cap)
            resolved = minBound - damped
        } else {
            resolved = unclamped
        }
        // Round to integer points so the card frame snaps to pixel
        // boundaries — fractional cardHeight values cause SwiftUI
        // to re-snap mid-drag, producing visible 1pt judder.
        // Final `max(0, …)` belt-and-suspenders against rubber-
        // band damping producing a negative value when `expanded`
        // is unusually small (early in the GeometryReader's life).
        return max(0, resolved.rounded())
    }

    /// Vertical swipe-anywhere gesture. Attached via
    /// `simultaneousGesture` to the pager's ScrollView so it
    /// recognizes alongside the horizontal pan.
    ///
    /// Lower `minimumDistance` (8pt) for responsiveness; the
    /// vertical-dominance check filters horizontal pans so the
    /// pager's paging snap stays clean. The activation offset
    /// captures `translation.height` at the moment we commit to
    /// vertical and subtracts it from subsequent updates, so the
    /// card's `dragTranslation` starts at 0 — no jump from the
    /// gesture's deadzone.
    private var verticalCardDragGesture: some Gesture {
        // CRITICAL: `coordinateSpace: .global` — translation reads
        // from the fixed window space, not the ScrollView's local
        // space. The ScrollView's frame moves as `cardHeight`
        // grows/shrinks during the drag (because the Spacer above
        // it adjusts), so a `.local` translation creates a
        // feedback loop: each grow moves the ScrollView's origin,
        // which makes the next gesture tick report less movement
        // than the finger actually did, which shrinks the card,
        // which moves the origin back, etc. The result is the
        // visible "few pixels up, then reset, repeat" judder
        // even though the finger is moving smoothly.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                if dragActivationOffset == nil {
                    guard abs(dy) > abs(dx) else { return }
                    dragActivationOffset = dy
                    // Lock the horizontal pager for the rest of
                    // the gesture so the ScrollView can't end up
                    // stuck between pages while we're resizing.
                    verticalDragActive = true
                }
                let adjusted = dy - (dragActivationOffset ?? 0)
                // Apply via a non-animating transaction so the live
                // drag update is delivered without inheriting any
                // implicit animation from a parent transaction.
                // Always update — `computeCardHeight` applies
                // rubber-band damping when the result would land
                // past the natural [collapsed, expanded] range.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    dragTranslation = adjusted
                }
            }
            .onEnded { value in
                if dragActivationOffset != nil, let vin = currentVin {
                    let predicted = value.predictedEndTranslation.height
                        - (dragActivationOffset ?? 0)
                    // Drag affects ONLY the currently-visible card's
                    // detent. Other vehicles' state stays untouched.
                    switch detent(for: vin) {
                    case .collapsed:
                        if predicted < -snapThreshold { detents[vin] = .expanded }
                    case .expanded:
                        if predicted > snapThreshold { detents[vin] = .collapsed }
                    }
                }
                // Spring back from any rubber-band overdrag to the
                // detent's natural position. Animated reset rather
                // than instant snap so the card eases back to the
                // boundary smoothly.
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    dragTranslation = 0
                }
                let wasActive = verticalDragActive
                dragActivationOffset = nil
                verticalDragActive = false
                if wasActive {
                    // Force the pager to snap to the current page
                    // in case a few pixels of horizontal offset
                    // slipped in before the vertical drag committed.
                    pagerResnapTrigger &+= 1
                }
            }
    }

    @ViewBuilder
    private func pagerScrollView(geo: GeometryProxy) -> some View {
        // ScrollViewReader (+ `.onScrollPhaseChange` for sync)
        // instead of `.scrollPosition(id:)`. The latter's
        // bidirectional binding was interacting badly with our
        // vertical `.simultaneousGesture`, causing pages to
        // commit between snap targets. Decoupling read (phase
        // change → index) from write (selection change →
        // scrollTo) breaks that loop.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Bottom-align cards in the HStack. Default HStack
                // alignment is vertical center, which means when one
                // card has an error overhead and another doesn't, the
                // shorter card's bottom shifts up by half the
                // difference — and during a vertical drag (when
                // `cardHeight` and the HStack's max child height
                // change), that center can micro-shift, producing
                // the 1–2pt up/down judder. Bottom alignment pins
                // each card's bottom to the HStack's bottom, so
                // resize only moves the top edge.
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(bbVehicles.enumerated()), id: \.element.id) { index, vehicle in
                        PersistentVehicleSheet(
                            bbVehicle: vehicle,
                            bbVehicles: bbVehicles,
                            selectedIndex: selectedVehicleIndex,
                            detent: detentBinding(for: vehicle.vin),
                            cardHeight: cardHeight(for: vehicle.vin, geo: geo),
                            onSuccessfulRefresh: onSuccessfulRefresh,
                            mfaState: mfaState,
                            sheetPresentation: sheetPresentation
                        )
                        .containerRelativeFrame(.horizontal)
                        .onPreferenceChange(ContentHeightPreferenceKey.self) { value in
                            let rounded = (value * 2).rounded() / 2
                            let vin = vehicle.vin
                            if abs((naturalHeights[vin] ?? 0) - rounded) > 0.5 {
                                naturalHeights[vin] = rounded
                            }
                        }
                        .onPreferenceChange(ErrorOverheadPreferenceKey.self) { value in
                            let rounded = (value * 2).rounded() / 2
                            let vin = vehicle.vin
                            if abs((errorOverheads[vin] ?? 0) - rounded) > 0.5 {
                                errorOverheads[vin] = rounded
                            }
                        }
                        .onPreferenceChange(ControlsHeightPreferenceKey.self) { value in
                            let rounded = (value * 2).rounded() / 2
                            let vin = vehicle.vin
                            if abs((controlsHeights[vin] ?? 0) - rounded) > 0.5 {
                                controlsHeights[vin] = rounded
                            }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // Disable horizontal scrolling while a vertical drag
            // is in progress — otherwise the user can leave the
            // pager stuck between pages when they transition from
            // a horizontal pan into a vertical resize.
            .scrollDisabled(bbVehicles.count <= 1 || verticalDragActive)
            .onScrollPhaseChange { old, new, context in
                BBLogger.info(.app, "[SVI] pager scroll phase \(old) → \(new), offsetX=\(context.geometry.contentOffset.x), width=\(context.geometry.containerSize.width)")
                // Only commit a selection change when the scroll
                // has fully settled — avoids the mid-drag thrash
                // that the `.scrollPosition` binding caused.
                guard new == .idle else { return }
                let width = context.geometry.containerSize.width
                guard width > 0 else { return }
                let index = Int(
                    (context.geometry.contentOffset.x / width).rounded()
                )
                let clamped = max(0, min(bbVehicles.count - 1, index))
                if clamped != selectedVehicleIndex {
                    BBLogger.info(.app, "[SVI] pager onScrollPhaseChange setting \(selectedVehicleIndex) → \(clamped)")
                    selectedVehicleIndex = clamped
                    // Detent is per-VIN now (see `detents`) — no
                    // reset on swipe. Each vehicle keeps whatever
                    // expanded/collapsed state the user last gave it.
                }
            }
            .onChange(of: selectedVehicleIndex) { _, new in
                withAnimation {
                    proxy.scrollTo(new, anchor: .leading)
                }
            }
            // Re-snap after a vertical drag — if a few pixels of
            // horizontal offset slipped in before the gesture
            // committed to vertical, this puts the pager back on
            // the current page.
            .onChange(of: pagerResnapTrigger) { _, _ in
                withAnimation {
                    proxy.scrollTo(selectedVehicleIndex, anchor: .leading)
                }
            }
            .onAppear {
                BBLogger.info(.app, "[SVI] pager .onAppear (idx=\(selectedVehicleIndex), count=\(bbVehicles.count))")
                proxy.scrollTo(selectedVehicleIndex, anchor: .leading)
            }
        }
    }
}

// MARK: - Misc

private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.max(lower, Swift.min(upper, value))
}
