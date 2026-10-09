//
//  PersistentVehicleSheet.swift
//  BetterBlue
//
//  Persistent bottom panel with two detents, shaped like a system
//  sheet: collapsed, an inset glass card floating over the map, the
//  same height for every vehicle and tall enough for any vehicle's
//  main controls; expanded, it fills the window up to the status bar,
//  edge to edge. Unlike a real `.sheet(isPresented:)` it:
//    - Lives in `MainView`'s root ZStack, above the navigation stack,
//      so the expanded card covers the toolbar like a sheet would.
//    - Doesn't compete with other `.sheet` modifiers — opening
//      Settings (a real sheet) no longer animates this panel away.
//    - Is continuously presented (no dismiss affordance, no
//      `interactiveDismissDisabled` needed — there's no SwiftUI
//      sheet machinery in the loop at all).
//
//  Section order, carried over from the card UI this replaced so
//  muscle memory survives: header (name + refresh) → EV range →
//  charging → gas range → lock → climate → action tiles → details.
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
    /// `VehicleSheetPager` (see `cardLayout(for:geo:)`) and passed
    /// down. The card has no GeometryReader of its own; the pager
    /// handles sizing so it can constrain its outer ScrollView frame
    /// and let map taps pass through above the card.
    let cardHeight: CGFloat
    /// Gap between the card and the page's side and bottom edges:
    /// `outerInset` while collapsed (a floating card), shrinking to 0
    /// as the card expands so the chrome grows out to the edges and
    /// the expanded card reads as a full-height system sheet.
    let edgeInset: CGFloat
    /// Distance the card's top edge rises from collapsed to expanded.
    /// The first `expansionTravel` points of scroll offset raise the
    /// card (the content stays pinned to its top edge); beyond that
    /// the content scrolls, under the header, which stays put. Because
    /// it is one scroll the whole way, a drag carries continuously from
    /// growing the card into scrolling its content and back. Zero when
    /// the window is too short for the card to expand — the content
    /// then simply scrolls.
    let expansionTravel: CGFloat
    /// The card's fully expanded height. The inner ScrollView keeps
    /// this fixed frame (top-aligned inside the card's clip) instead of
    /// following `cardHeight`: resizing a ScrollView mid-interaction
    /// makes SwiftUI insert a compensating content inset that never
    /// unwinds, and drops programmatic scrolls. The card sits on the
    /// window's bottom edge, so the part of the ScrollView below the
    /// clip is offscreen and untouchable.
    let expandedHeight: CGFloat
    /// How far along `expansionTravel` the card is: 0 collapsed, 1
    /// expanded. Fades in the opaque backing that turns the glass
    /// card into a solid sheet.
    let expansionProgress: CGFloat
    /// True when the card is a column on the leading side of a wider
    /// window rather than spanning it (see
    /// `VehicleSheetPager.maxSheetWidth`). A card that spans the
    /// window is shaped like a system sheet; a column keeps corners of
    /// its own — see `cardShape`.
    let isColumn: Bool
    /// True where the card's bottom corners have no display corner to
    /// close in on, and square off on the way as the card expands rather
    /// than once it has landed — see `cardShape`.
    let squaresBottomWhenExpanded: Bool
    /// Height of the window's bottom safe area (the home-indicator
    /// strip). The pager lays the cards out through it, so the content
    /// pads its own tail by this much to end clear of the indicator.
    let bottomSafeAreaInset: CGFloat
    /// Where the card reports the live vertical content offset of its
    /// inner ScrollView, which the pager turns into the card height.
    /// Written straight from the scroll, so that it costs the card no
    /// redraw of its own on top of the pager's.
    let scrollOffsets: SheetScrollOffsets
    /// The live offset, where `DetentSnapBehavior` and the detent
    /// bookkeeping can read it.
    @State private var offsetTracker = ScrollOffsetTracker()
    /// Springs the scroll to a detent — after a release, or when the
    /// detent is changed from outside the scroll.
    @State private var springDriver = SheetSpringDriver()
    /// Explicit scroll position, used to spring the scroll to a detent.
    @State private var scroll = ScrollPositionBox()
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
    // Fed by `waitForStatusChange`'s statusMessageUpdater closure.
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

    /// Gap around the collapsed card's sides and bottom — the card
    /// "floats" inside it. Bottom matches sides so the spacing is
    /// uniform. The live gap is `edgeInset`, which starts here and
    /// closes as the card expands.
    private let outerInset: CGFloat = 8
    /// Clear space between the error card and the main card below it.
    private let errorCardGap: CGFloat = 16
    /// Floor for the card's concentric corners. Their real radius comes
    /// from `ConcentricRectangle`: SwiftUI derives it from the
    /// enclosing container's corner — the device display when the app
    /// is full screen, the window when it's an iPadOS / Mac window —
    /// minus the card's inset from that corner.
    private let minimumCornerRadius: CGFloat = 24

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
        VStack(spacing: 0) {
            if let errorMessage {
                errorCardView(errorMessage)
            }
            mainCardBody
        }
        // No card-wide DragGesture — the *vertical* swipe-anywhere
        // behavior belongs to the inner vertical ScrollView in
        // `mainCardBody`, which doesn't conflict with the parent
        // horizontal pager because the gestures are perpendicular.
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

    /// Main glass card body. Single, linear pipeline so the glass +
    /// clip use the SAME shape sized to the SAME frame — no separate
    /// mask/frame/padding chain to keep in sync.
    ///
    /// Pipeline:
    ///   contentStack
    ///     inner padding
    ///     padded out to at least the expanded height
    ///     the header laid over it, pinned (`pinnedHeader`)
    ///     ScrollView, fixed at the page width × the expanded height
    ///     bounded to cardHeight (top-anchored — content above the
    ///       clip line stays put when the card shrinks)
    ///     narrowed by `edgeInset` per side WITHOUT resizing the
    ///       ScrollView (the negative padding)
    ///     glass background in the card shape
    ///     clipShape (clips whatever overflows the card)
    ///     outer `edgeInset` padding on the sides and bottom
    ///
    /// So as the card expands only the chrome moves: its top edge
    /// rises with the scroll while its sides and bottom grow out to
    /// the page edges. The ScrollView holds still underneath; its
    /// content only follows the card's sides outward (see the side
    /// margin below).
    @ViewBuilder
    private var mainCardBody: some View {
        let shape = cardShape
        // The opaque fill that comes up over the glass across the upper
        // half of the expansion (see the background below).
        let sheetOpacity = min(1, max(0, expansionProgress * 2 - 1))
        // Vertical ScrollView that owns the card's vertical gesture.
        // The first `expansionTravel` points of scroll offset are
        // absorbed into raising the card — the content is shifted down
        // by the same amount so it stays pinned to the card's top edge
        // — and past that the content scrolls, under the header, which
        // stays where it is. Because it is one UIScrollView pan the
        // whole way, a drag carries continuously from expanding into
        // scrolling, and dragging back through the top continues into
        // collapsing. A flick's momentum, though, stops at the expanded
        // detent — see `DetentSnapBehavior`.
        ScrollView(.vertical) {
            contentStack
                // Side margin, measured from the CARD's edge — hence
                // the `edgeInset`: the ScrollView spans the whole page
                // (see below), and the card's edge is that far inside
                // it. So the content keeps its distance from the edge
                // as the card grows outward, widening with it, the way
                // a system sheet's content does. Only widths change —
                // the rows are single lines, so nothing gets taller or
                // shorter mid-gesture. No top padding: the header row
                // brings its own (the drag handle sits above the title,
                // inside that margin).
                // The bottom also clears the home indicator, which the
                // expanded card runs underneath.
                .padding(.horizontal, SheetLayout.margin + edgeInset)
                .padding(.bottom, SheetLayout.foldMargin + bottomSafeAreaInset)
                // How tall the content is, for the pager to stop the
                // expanded card at (see `ContentHeightPreferenceKey`).
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                // At least as tall as the expanded card. The scrollable
                // range is then never less than `expansionTravel` (the
                // padding below), so the card can always reach its
                // expanded detent — even for a vehicle whose content
                // wouldn't fill the window.
                .frame(maxWidth: .infinity, minHeight: expandedHeight, alignment: .topLeading)
                // Extra scrollable room equal to the expansion
                // travel, so the bottom of the content is still
                // reachable after the first `expansionTravel` points
                // of offset were spent raising the card.
                .padding(.bottom, expansionTravel)
                // Pin the content while the card rises — and while it is
                // pulled down past its collapsed detent, where the
                // scroll's bounce would otherwise drop the content down
                // inside the card: the card gives way instead (see
                // `VehicleSheetPager.cardLayout(for:geo:)`), its content
                // going with its top edge. Read from the scroll as it is
                // drawn rather than from a state set off it, which would
                // redraw the whole card on every frame.
                .visualEffect { [expansionTravel] content, proxy in
                    content.offset(y: min(-proxy.frame(in: .scrollView).minY, expansionTravel))
                }
                // Outside that pin, which it would otherwise ride on top
                // of — it has one of its own.
                .overlay(alignment: .top) {
                    pinnedHeader
                }
        }
        .modifier(BoxedScrollPosition(box: scroll))
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollTargetBehavior(DetentSnapBehavior(travel: expansionTravel, tracker: offsetTracker))
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            guard offset.isFinite else { return }
            offsetTracker.offset = offset
            scrollOffsets.report(offset, for: bbVehicle.vin)
            // Scrolled by something other than a finger or the card's own
            // spring (see `settleWhenStill(at:)`).
            if offsetTracker.phase == .idle, !springDriver.isRunning {
                settleWhenStill(at: offset)
            }
        }
        // A drag let go partway through the travel stopped where it
        // was (see `DetentSnapBehavior`); spring it on to its detent
        // as soon as the finger is up, and keep the settling below out
        // of the way until it arrives.
        //
        // Otherwise see that the card rests at a detent, judged from
        // where the scroll came to rest. Read the offset from the
        // scroll itself: the offset reported to the pager can trail the
        // scroll by a frame here, and a test against it took a card that
        // had just snapped back up to expanded for a collapsed one — and
        // collapsed it.
        .onScrollPhaseChange { old, new, context in
            offsetTracker.phase = new
            if new == .interacting {
                springDriver.stop()
                offsetTracker.isScrollingInCode = false
                offsetTracker.settleCheck?.cancel()
                offsetTracker.settleRetries = 0
            }
            if old == .interacting, new != .interacting {
                let released = context.geometry.contentOffset.y
                let isPartway = released > 0 && released < expansionTravel - 0.5
                if offsetTracker.isSnapPending || isPartway {
                    offsetTracker.isSnapPending = false
                    let velocity = offsetTracker.releaseVelocity
                    let snap = SheetSnap(released: released, velocity: velocity, travel: expansionTravel)
                    if isPartway {
                        springToDetent(snap.offset, from: released, velocity: velocity, spring: snap.spring)
                    } else if released > 0 {
                        // Let go in the content after all (the card already
                        // expanded): its momentum stops at the top of it.
                        springToDetent(expansionTravel, from: released, velocity: velocity, spring: snap.spring)
                    } else {
                        // Let go at or below the collapsed detent after all.
                        // A fast flick down can get there before its release
                        // is seen, and stays collapsed; a card pulled down
                        // and flicked back up goes where the flick sends it.
                        let expands = snap.offset > 0
                        springToDetent(
                            snap.offset,
                            from: released,
                            velocity: expands ? velocity : 0,
                            spring: expands ? snap.spring : SheetSnap.spring
                        )
                    }
                    return
                }
            }
            guard new == .idle, !springDriver.isRunning else { return }
            settleWhenStill(at: context.geometry.contentOffset.y)
        }
        // Detent changed from outside the scroll (drag-handle tap):
        // scroll to the matching offset so the height follows.
        .onChange(of: detent) { _, new in
            // Loose: a spring that just set the detent on arriving can
            // leave the offset a frame behind it.
            let needsMove = new == .expanded
                ? offsetTracker.offset < expansionTravel - 2
                : offsetTracker.offset > 2
            guard needsMove else { return }
            springToDetent(
                new == .expanded ? expansionTravel : 0,
                from: offsetTracker.offset,
                velocity: 0,
                spring: SheetSnap.spring
            )
        }
        // The room to expand into changed under an expanded card
        // (rotation, window resize, an error card appearing above it).
        // The scroll offset still holds the OLD travel, which would
        // leave the card short of — or scrolled past — its new expanded
        // height, so shift it by the difference: the card stays
        // expanded and its content stays where it was. Whatever the
        // card was doing, see that it ends at one of the new detents —
        // a spring under way still heads for an old one.
        .onChange(of: expansionTravel, initial: true) { old, new in
            offsetTracker.travel = new
            defer { settleWhenStill(at: offsetTracker.offset) }
            guard old > 0, new > 0, old != new, offsetTracker.offset >= old - 0.5 else { return }
            let target = offsetTracker.offset + (new - old)
            // Next tick, not now: the travel changes together with
            // `expandedHeight` — this ScrollView's frame — and a
            // programmatic scroll issued while a ScrollView is being
            // resized is dropped.
            Task { @MainActor in
                springDriver.stop()
                offsetTracker.isScrollingInCode = true
                scroll.position.scrollTo(y: target)
            }
        }
        // Fixed ScrollView frame (see `expandedHeight`), then the
        // card's clip frame at the current card height. Content
        // above the clip line is preserved (top alignment); overflow
        // is removed by the clip in `SheetChrome`.
        .frame(height: expandedHeight, alignment: .top)
        .frame(height: cardHeight, alignment: .top)
        // The collapsed card's bottom edge is a fold: whatever room
        // the vehicle's controls leave above it shows the start of
        // the next section, usually cut off mid-row. Fade that last
        // stretch out so it reads as "more below" rather than as a
        // sliced row. The fade is no taller than the margin kept
        // under the tallest controls, so it never touches a control,
        // and it is gone by the time the card is expanded, when its
        // bottom edge is the screen's.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(
                    colors: [.black, .black.opacity(expansionProgress)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: SheetLayout.foldMargin)
            }
        }
        // The card is `edgeInset` narrower than the page on each side;
        // hand that width straight back to the ScrollView so IT stays
        // page-wide whatever the inset — same reason its height is
        // fixed. The overhang is clipped off with everything else.
        .padding(.horizontal, -edgeInset)
        // Glass behind content, in the SAME shape used by clip. Over
        // the upper half of the expansion an opaque fill comes up
        // over the glass: a floating card can afford to show the map
        // through it, a window-filling sheet of text can't — the
        // same switch the system's own sheets make at full height.
        .background {
            Color.clear.glassEffect(.regular, in: shape)
            shape
                .fill(Color(uiColor: .sheetBackground))
                .opacity(sheetOpacity)
        }
        // Clips the glass and any overflowing content to the card
        // shape, and draws its edge — until the card has become a
        // full-window sheet. A column still floats over the map
        // beside it, so it keeps its edge.
        .modifier(SheetChrome(shape: shape, floating: isColumn ? 1 : 1 - sheetOpacity))
        // The gap the collapsed card floats in; gone once expanded.
        .padding(.horizontal, edgeInset)
        .padding(.bottom, edgeInset)
    }

    /// Springs the scroll from `from` to a detent's offset, and settles
    /// the detent flag when it arrives.
    private func springToDetent(_ offset: CGFloat, from: CGFloat, velocity: CGFloat, spring: Spring) {
        offsetTracker.isScrollingInCode = true
        springDriver.run(
            from: from,
            to: offset,
            velocity: velocity,
            spring: spring,
            takingOver: offsetTracker.phase != .idle
        ) { y in
            scroll.position.scrollTo(y: y)
        } completion: {
            let settled: SheetDetent = offset > 0 ? .expanded : .collapsed
            if detent != settled { detent = settled }
            // The room to expand into may have changed on the way.
            settleWhenStill(at: offsetTracker.offset)
        }
    }

    /// Sees that a card the scroll has left alone rests at a detent. A
    /// finger's release and the card's own spring always end at one,
    /// but a scroll nothing here drives — the status bar's
    /// scroll-to-top, a pointer's scroll wheel, the travel changing
    /// under a spring — can stop anywhere, and reports no phase change
    /// to settle on. So once the scroll has been still for a moment, a
    /// card left between its detents springs on to the nearer one.
    /// Wherever it rests, `detent` follows: left claiming the detent the
    /// card was scrolled away from, it would make the drag handle's
    /// next tap do nothing.
    private func settleWhenStill(at offset: CGFloat) {
        offsetTracker.settleCheck?.cancel()
        guard isBetweenDetents(offset) else {
            recordDetent(at: offset)
            return
        }
        offsetTracker.settleCheck = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, offsetTracker.phase == .idle, !springDriver.isRunning else { return }
            let offset = offsetTracker.offset
            let travel = offsetTracker.travel
            if isBetweenDetents(offset) {
                // A scroll that doesn't follow the spring would be sprung
                // at again every time it finished, without end. Three
                // tries from the same spot, then the card stays put.
                if abs(offset - offsetTracker.settleOffset) < 0.5 {
                    offsetTracker.settleRetries += 1
                } else {
                    offsetTracker.settleOffset = offset
                    offsetTracker.settleRetries = 0
                }
                guard offsetTracker.settleRetries < 3 else {
                    recordDetent(at: offset)
                    return
                }
                springToDetent(offset > travel / 2 ? travel : 0, from: offset, velocity: 0, spring: SheetSnap.spring)
            } else {
                recordDetent(at: offset)
            }
        }
    }

    /// Whether a card at `offset` stands between its detents, rather than
    /// at one or (past the expanded one) scrolling its content.
    private func isBetweenDetents(_ offset: CGFloat) -> Bool {
        offset > 1 && offset < offsetTracker.travel - 1
    }

    /// Records which detent a card resting at `offset` is at.
    private func recordDetent(at offset: CGFloat) {
        let travel = offsetTracker.travel
        let settled: SheetDetent = travel > 0 && offset > travel / 2 ? .expanded : .collapsed
        if detent != settled { detent = settled }
    }

    /// The card's outline.
    ///
    /// Spanning the window, it is a system sheet's: top corners at a
    /// sheet's fixed `SheetLayout.sheetTopCornerRadius`, bottom
    /// corners concentric with the display. Collapsed, that is a
    /// floating card whose bottom nests in the display's curve; as the
    /// card expands, `edgeInset` shrinks away and the very same shape
    /// moves out into the window's bottom corners, leaving a rounded top
    /// and nothing to see at the bottom, like a full-height sheet.
    ///
    /// Once it is there, its bottom corners are squared off and left
    /// for the display (or the window) to round. A concentric corner
    /// at no inset is only nearly the display's own: on an iPhone 17
    /// Pro it starts curving a pixel or two higher up the sides and
    /// meets the bottom edge some 40–60 pixels further in, which left a
    /// hairline of map showing around both corners. Square, the card
    /// fills the corner and the display's mask cuts it exactly.
    ///
    /// Bottom corners with no display corner to close in on
    /// (`squaresBottomWhenExpanded`) sit on the `minimumCornerRadius`
    /// floor, and that floor sinks to nothing as the card lands, so
    /// that they square off on the way.
    ///
    /// A column (`isColumn`) is no sheet: it stays a uniform concentric
    /// rounded rectangle — every corner on the floor, in practice —
    /// until its bottom corners square off the same way.
    private var cardShape: ConcentricRectangle {
        let concentric = Edge.Corner.Style.concentric(minimum: .fixed(minimumCornerRadius))
        if isColumn, edgeInset >= outerInset {
            return ConcentricRectangle(corners: concentric, isUniform: true)
        }
        let top = isColumn ? concentric : .fixed(SheetLayout.sheetTopCornerRadius)
        // Within half a point of landing the switch can't be seen: all
        // that a square corner adds there lies outside the display's
        // rounded one, but for a sliver too thin to show.
        let bottom: Edge.Corner.Style = if edgeInset < 0.5 {
            .fixed(0)
        } else if squaresBottomWhenExpanded {
            .concentric(minimum: .fixed(minimumCornerRadius * edgeInset / outerInset))
        } else {
            concentric
        }
        return ConcentricRectangle(
            uniformTopCorners: top,
            bottomLeadingCorner: bottom,
            bottomTrailingCorner: bottom
        )
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
            .modifier(SheetChrome(shape: shape))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, outerInset)
        .padding(.top, outerInset)
        .padding(.bottom, errorCardGap)
        // Report only the error card's own outer height, gap
        // included — stable measurement that doesn't change with
        // `cardHeight`. The pager adds this to its ScrollView frame
        // so the error card fits above the main card, and lowers the
        // expanded card by as much to keep the banner on screen.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ErrorOverheadPreferenceKey.self,
                    value: proxy.size.height
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
        // Just under the card's top edge, where a system sheet keeps
        // its grabber.
        .padding(.top, 6)
        // The capsule is a 5pt sliver; its tap target is a full-size
        // one around it. Centered and no wider than it needs to be: it
        // lies over the top of the header row, and must stay clear of
        // the refresh button at the row's trailing end. (Under it there
        // is only the title, which isn't a control.)
        .frame(minWidth: 88, minHeight: TapTarget.minimumSize, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            guard expansionTravel > 0 else { return }
            detent = detent == .collapsed ? .expanded : .collapsed
        }
        // No local drag gesture — vertical swipes anywhere on the
        // card, the handle included, belong to the ScrollView in
        // `mainCardBody`.
    }

    // MARK: - Content stack (sections)

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: SheetLayout.sectionSpacing) {
            // Controls section (header + ranges + lock + climate) —
            // everything the collapsed card promises to show. Wrapped
            // in its own VStack with a GeometryReader so its height
            // can be reported up to the pager, which never lets the
            // collapsed card be shorter than any vehicle's controls.
            // Keep the rows in step with `ControlsSizingTemplate`.
            VStack(alignment: .leading, spacing: SheetLayout.rowSpacing) {
                // The header's room. The header itself is drawn over the
                // content, pinned to the top of the card (see
                // `pinnedHeader`); laid out here, unseen, it still puts
                // the rows below it and counts in the controls' height.
                headerRow
                    .hidden()
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
            actionTiles
            detailRows
        }
    }

    // MARK: - Header (ZStack: title + drag handle + refresh button)

    /// The header, held at the top of the card whatever the scroll: it
    /// rises with the card's top edge as the card expands, and stays put
    /// while the content scrolls up under it. It belongs to the scroll
    /// content, pinned against the scroll the way the content is while
    /// the card rises, rather than being laid over the ScrollView: a drag
    /// that starts on it — on the drag handle above all — must still move
    /// the card.
    @ViewBuilder
    private var pinnedHeader: some View {
        let travel = expansionTravel
        let fadeIn = SheetLayout.headerFadeIn
        headerRow
            .padding(.horizontal, SheetLayout.margin + edgeInset)
            // All of it the header's to tap, its backing's overhang
            // included, so that a tap on it can't land on a row scrolled
            // under it.
            .padding(.bottom, SheetLayout.headerOverhang)
            .contentShape(Rectangle())
            .padding(.bottom, -SheetLayout.headerOverhang)
            .visualEffect { content, proxy in
                content.offset(y: -proxy.frame(in: .scrollView).minY)
            }
            // Pinned the same way, by an effect of its own. Only content
            // scrolled on past the expanded detent goes under the header,
            // so only then do the backing and its border come in.
            .background(alignment: .top) {
                HeaderBackdrop(isOpaque: travel > 0)
                    .visualEffect { content, proxy in
                        let offset = -proxy.frame(in: .scrollView).minY
                        return content
                            .offset(y: offset)
                            .opacity(min(1, max(0, (offset - travel) / fadeIn)))
                    }
            }
    }

    @ViewBuilder
    private var headerRow: some View {
        // ZStack of header elements: title + drag handle +
        // refresh button. The HStack of title+refresh is offset
        // down by the card's margin, and the handle sits above
        // them inside that margin, at the very top of the row.
        ZStack(alignment: .top) {
            // Title (leading) + refresh button (trailing).
            //
            // `alignment: .top` (not `.center`) so the refresh
            // button's top edge sits exactly at the HStack content
            // top. With `.center`, the taller title VStack (title +
            // "Updated" subtitle) pushes the centered button down
            // by a point or two, breaking the uniform top/trailing
            // margin equation.
            HStack(alignment: .top) {
                // Server timestamp sits right under the title — when
                // "was it updated recently?" is the question, having
                // the answer here beats making the user scroll. VIN
                // lives in the detail rows since it's reference info,
                // not glanceable.
                SheetTitle(
                    name: bbVehicle.displayName,
                    updated: bbVehicle.lastUpdated.map { formatLastUpdated($0) }
                )
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
            // The same margin above as at the sides. With it the
            // refresh button — `margin` from the top and from the
            // trailing edge — sits concentric in a sheet-shaped
            // card's top corner (margin + the button's radius =
            // `SheetLayout.sheetTopCornerRadius`), and the handle
            // (its capsule ends at y=11) keeps 5pt of breathing room
            // over the title.
            .padding(.top, SheetLayout.margin)
            // Drag handle anchored at the very top of the ZStack.
            dragHandle
        }
    }

    // MARK: - Sections

    /// Compact EV range row. Used for all vehicles with an EV
    /// drivetrain (pure EV + PHEV). Aligns with the SectionRow icon
    /// column, range left, percentage right, and an
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

        RangeRow(
            systemImage: batterySymbol(for: ev.evRange.percentage),
            tint: tint,
            range: formattedRange,
            percentage: ev.evRange.percentage
        ) {
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
                SlimProgressBar(
                    percentage: ev.evRange.percentage,
                    tint: tint
                )
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
        RangeRow(
            systemImage: "fuelpump.fill",
            tint: tint,
            range: formattedRange,
            percentage: gas.percentage
        ) {
            SlimProgressBar(percentage: gas.percentage, tint: tint)
        }
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
            // active. The trailing quick-action button stays static.
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
            if let battery12V = bbVehicle.battery12V, battery12V >= 0 && battery12V <= 100 {
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

    // MARK: - Action tiles

    /// The vehicle's secondary actions, as tiles between the controls and
    /// the detail rows (see `SheetActionGrid`): navigation, trip history,
    /// surround view, the charging and climate settings, and the info
    /// sheets. Actions a vehicle doesn't support are simply left out.
    @ViewBuilder
    private var actionTiles: some View {
        SheetActionGrid {
            if let location = safeLocation {
                navigateTile(to: location)
            }

            if bbVehicle.fuelType.hasElectricCapability,
               bbVehicle.account?.supportedEVTripTypes.contains(.summary) == true {
                actionTile("Trip History", systemImage: "chart.line.uptrend.xyaxis") {
                    sheetPresentation.show(.tripDetails(vehicle: bbVehicle))
                }
            }

            if bbVehicle.showsSurroundView {
                actionTile("Surround View", systemImage: "camera.viewfinder") {
                    sheetPresentation.show(.surroundView(vehicle: bbVehicle))
                }
            }

            // Settings behind the controls above, in the controls'
            // order. Each is also in its row's menu (the charging and
            // climate rows); here they can be found without knowing
            // those rows open one. Charge limits only for a
            // vehicle that charges — the same rule as Vehicle Info's
            // EV Settings.
            if bbVehicle.fuelType.hasElectricCapability {
                actionTile("Charge Limits", systemImage: "battery.100percent") {
                    sheetPresentation.show(.chargeLimitSettings(vehicle: bbVehicle))
                }
            }

            actionTile("Climate Settings", systemImage: "fan") {
                sheetPresentation.show(.climateSettings(vehicle: bbVehicle))
            }

            actionTile("Vehicle Info", systemImage: "car.fill") {
                sheetPresentation.show(.vehicleInfo(vehicle: bbVehicle))
            }

            if let account = bbVehicle.account {
                actionTile("Account Info", systemImage: "person.circle") {
                    sheetPresentation.show(.accountInfo(account: account))
                }

                if AppSettings.shared.debugModeEnabled {
                    actionTile("HTTP Logs", systemImage: "network") {
                        sheetPresentation.show(.httpLogs(account: account))
                    }
                }

                if account.brandEnum == .fake {
                    actionTile("Configure Vehicle", systemImage: "gearshape.fill") {
                        sheetPresentation.show(.vehicleConfiguration(vehicle: bbVehicle))
                    }
                }
            }
        }
    }

    /// A tile that opens one of the per-vehicle sheets.
    private func actionTile(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            SheetActionTile(
                title: title,
                systemImage: systemImage,
                tint: bbVehicle.primaryColor
            )
        }
        .buttonStyle(SheetActionButtonStyle())
    }

    /// "Navigate to Vehicle" — hands off to a maps app. With more than
    /// one maps app to choose from, tapping the tile offers them in a
    /// menu.
    @ViewBuilder
    private func navigateTile(to location: VehicleStatus.Location) -> some View {
        let availableApps = NavigationHelper.availableMapApps
        let coordinate = CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        )
        let destinationName = bbVehicle.displayName
        let label = SheetActionTile(
            title: "Navigate to Vehicle",
            systemImage: "location",
            tint: bbVehicle.primaryColor
        )
        if availableApps.count == 1 {
            Button {
                NavigationHelper.navigate(
                    using: availableApps[0],
                    to: coordinate,
                    destinationName: destinationName
                )
            } label: {
                label
            }
            .buttonStyle(SheetActionButtonStyle())
        } else {
            Menu {
                NavigationMenuContent(
                    coordinate: coordinate,
                    destinationName: destinationName
                )
            } label: {
                label
            }
            .buttonStyle(.plain)
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
                // Poke status immediately so the Live Activity ends
                // even if the wait below times out.
                try? await account.fetchAndUpdateVehicleStatus(
                    for: bbVehicle, modelContext: context, cached: false
                )
            }
            // Charging state propagates slowest through the backends —
            // give it a longer window.
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
        // The vehicle was removed while the action was under way (see
        // `BBVehicle.liveVehicle()`): nothing to report, its card is going.
        if error is CancellationError { return }
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

    /// Map an APIError to the friendly banner text.
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
        case .featureNotSupported:
            return error.message
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

// MARK: - Controls layout

/// The grid every row of the card is laid out on, so the controls and
/// the details line up:
///
///     margin │ icon column │ text ………………………………… trailing │ margin
///       16       36pt    12                                    16
///
/// Every row's icon is centered in the same column, every row's text
/// starts on the same line, and every row's trailing element — action
/// button, percentage, value — ends on the same line, `margin` from the
/// card's edge, under the header's refresh button. The action tiles
/// between them span the same width (see `SheetActionGrid`).
private enum SheetLayout {
    /// Clear space between the card's edge and its content, at the
    /// sides and at the top — what a system sheet keeps around its own
    /// content.
    static let margin: CGFloat = 16
    /// Width of the leading icon column; icons are centered in it.
    static let iconColumn: CGFloat = 36
    /// Icon column → text.
    static let iconSpacing: CGFloat = 12
    /// How far the pinned header's backing, and the border along its
    /// bottom, reach below the header itself (see `HeaderBackdrop`): the
    /// header ends where its title and button do, too tight for a border.
    /// Half the gap to the first row.
    static let headerOverhang: CGFloat = rowSpacing / 2
    /// How far content scrolls under the header before the header's
    /// backing and border are fully in: as far as the first row has to
    /// come to reach the backing's lower edge, so that nothing shows
    /// through it.
    static let headerFadeIn: CGFloat = rowSpacing - headerOverhang
    /// Space kept under the last thing in view at the card's bottom
    /// edge: under the controls at the collapsed fold (below which the
    /// rest of the content waits for the card to expand), and under
    /// the end of the content. More than `margin` because the
    /// collapsed card's bottom corners, concentric with the display,
    /// are far rounder than its top ones.
    static let foldMargin: CGFloat = 22
    /// Vertical gap between the main controls' rows. One value for all
    /// of them, so the controls fall into an even rhythm — wide enough
    /// that the stacked action buttons read as separate buttons.
    static let rowSpacing: CGFloat = 16
    /// Vertical gap between sections (controls, action list, details).
    /// A hair more than `foldMargin`: for a vehicle whose controls fill
    /// the collapsed card exactly, the action list starts just out of
    /// sight instead of showing as a sliver along the card's bottom
    /// edge.
    static let sectionSpacing: CGFloat = foldMargin + 2
    /// Top corner radius of a card that spans the window: a system
    /// sheet's. Sheets keep this one radius at every detent — floating
    /// at partial height and edge to edge at full height alike — and
    /// on every display, round-cornered or square; only their bottom
    /// corners follow the display. (Measured on iOS 26 and 27.)
    static let sheetTopCornerRadius: CGFloat = 38
    /// Corner radius of the cards inside the sheet: concentric with
    /// the sheet's own top corners, `margin` inside them.
    static let innerCornerRadius: CGFloat = sheetTopCornerRadius - margin
}

/// Stand-in for the tallest stack of main controls any vehicle can
/// show: a plug-in hybrid (gas + EV rows) in the middle of a charge
/// (the EV row's thick charging bar). Never drawn —
/// `VehicleSheetPager` lays it out hidden and sizes EVERY collapsed
/// card from it, so the collapsed height is the same whatever the
/// vehicle and still fits any vehicle's controls. Built from the same
/// row views as the real thing so fonts and Dynamic Type can't pull
/// the two apart; keep the row list in step with
/// `PersistentVehicleSheet.contentStack`.
private struct ControlsSizingTemplate: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SheetLayout.rowSpacing) {
            // Header: title + "updated" line beside the refresh button.
            HStack(alignment: .top) {
                SheetTitle(name: "Vehicle", updated: "Updated")
                Spacer(minLength: 0)
                buttonSlot
            }
            .padding(.top, SheetLayout.margin)
            RangeRow(systemImage: "fuelpump.fill", tint: .clear, range: "--", percentage: 0) {
                SlimProgressBar(percentage: 0, tint: .clear)
            }
            RangeRow(systemImage: "battery.100percent", tint: .clear, range: "--", percentage: 0) {
                EVChargingProgressView(
                    batteryPercentage: 0,
                    isCharging: true,
                    chargeSpeed: nil,
                    chargeTimeRemaining: nil,
                    targetSOC: nil,
                    showHeader: false
                )
            }
            // Charging, lock, climate.
            ForEach(0 ..< 3, id: \.self) { _ in
                HStack(alignment: .center, spacing: SheetLayout.iconSpacing) {
                    SectionRowLabel(
                        icon: Image(systemName: "lock.fill"),
                        iconColor: .clear,
                        subtitle: "Status"
                    )
                    Spacer()
                    buttonSlot
                }
            }
        }
    }

    /// Footprint of a row's circular action button.
    private var buttonSlot: some View {
        Color.clear.frame(
            width: CircularIconLabel.standardDiameter,
            height: CircularIconLabel.standardDiameter
        )
    }
}

// MARK: - Header title

/// Vehicle name over its "last updated" line.
private struct SheetTitle: View {
    let name: String
    let updated: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
            if let updated {
                Text(updated)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// What the pinned header stands on once content has scrolled under it,
/// with a hairline border along its bottom edge, the way a navigation
/// bar sets itself off from content scrolled beneath it. It reaches a
/// little below the header (`SheetLayout.headerOverhang`). The card's own
/// opaque fill, which a card has always turned to by then (it had to
/// expand to get there) — unless it can't expand at all, when its content
/// scrolls inside a card that is still glass, and a material stands in.
private struct HeaderBackdrop: View {
    let isOpaque: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(
                isOpaque
                    ? AnyShapeStyle(Color(uiColor: .sheetBackground))
                    : AnyShapeStyle(.regularMaterial)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1 / displayScale)
            }
            .padding(.bottom, -SheetLayout.headerOverhang)
            .allowsHitTesting(false)
    }
}

// MARK: - Range row

/// Layout shared by the gas and EV range rows: fuel icon in the icon
/// column, range left, percentage right, and the caller's progress bar
/// underneath — all on `SheetLayout`'s grid.
private struct RangeRow<Bar: View>: View {
    let systemImage: String
    let tint: Color
    let range: String
    let percentage: Double
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        HStack(alignment: .center, spacing: SheetLayout.iconSpacing) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: SheetLayout.iconColumn, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(range)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(percentage))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                bar()
            }
        }
    }
}

/// 6pt capsule progress bar used by both the gas row and the
/// EV row's not-charging state. Gray background with a tinted
/// fill. Matches EVChargingProgressView's not-charging bar
/// thickness exactly.
private struct SlimProgressBar: View {
    let percentage: Double
    let tint: Color

    var body: some View {
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
}

// MARK: - Section row helper

/// Single horizontal row used by lock / climate / charging sections.
/// Left: status icon + title above subtitle, wrapped in a `Menu` so
/// tapping the row opens the same options as long-pressing the
/// trailing quick-action button. Right: caller-supplied trailing
/// content (the circular action button). The two tap targets tile
/// the row: the menu takes everything up to the button.
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
        HStack(alignment: .center, spacing: SheetLayout.iconSpacing) {
            Menu {
                menuContent()
            } label: {
                SectionRowLabel(
                    icon: icon,
                    iconColor: iconColor,
                    iconAnimation: iconAnimation,
                    title: title,
                    subtitle: subtitle
                )
                // The whole row up to the button is the tap target,
                // at the button's height — not just the icon and
                // however long its text happens to be.
                .frame(
                    maxWidth: .infinity,
                    minHeight: CircularIconLabel.standardDiameter,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Lay the button out by its circle; its tap target
            // reaches past that (see `CircularIconLabel.tapOutset`).
            trailing()
                .padding(-CircularIconLabel.tapOutset)
        }
    }
}

/// The leading half of a `SectionRow` — status icon beside its text.
/// Split out so `ControlsSizingTemplate` can measure a row without
/// standing up the menu and button around it.
private struct SectionRowLabel: View {
    let icon: Image
    let iconColor: Color
    var iconAnimation: AnimatedStatusIcon.Animation = .none
    var title: String?
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: SheetLayout.iconSpacing) {
            AnimatedStatusIcon(
                icon: icon,
                color: iconColor,
                animation: iconAnimation
            )
            .frame(width: SheetLayout.iconColumn, height: 32)
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
    }
}

// MARK: - Action tiles

/// The sheet's action tiles, in exactly two full rows: half of them,
/// rounded up, in the top row and the rest below, each row's tiles
/// sharing its width equally. However many actions a vehicle has, the
/// grid is never left with a gap — seven make four over three, the three
/// a third of the width each.
private struct SheetActionGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { tiles in
            let topRow = (tiles.count + 1) / 2
            let rows = [Array(tiles.prefix(topRow)), Array(tiles.dropFirst(topRow))]
                .filter { !$0.isEmpty }
            VStack(spacing: SheetActionTile.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: SheetActionTile.spacing) {
                        ForEach(rows[index]) { tile in
                            tile
                        }
                    }
                    // Every tile in the row as tall as its tallest.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One action tile: tinted icon and title. A tile wide enough — two or
/// three to a row — has its icon beside the title; a narrower one — four
/// or more to a row — has it above.
private struct SheetActionTile: View {
    let title: String
    let systemImage: String
    let tint: Color

    /// Gap between tiles, across and down.
    static let spacing: CGFloat = 8
    /// Concentric with the sheet's top corners, like any card inside it.
    static let shape = RoundedRectangle(cornerRadius: SheetLayout.innerCornerRadius, style: .continuous)

    /// Narrowest tile that has its icon beside the title: a third of an
    /// iPhone's card (~118pt) is wide enough, a quarter (~86pt) isn't.
    /// Scales with the text, so that larger type stacks sooner.
    @ScaledMetric(relativeTo: .caption) private var sideBySideWidth: CGFloat = 100

    var body: some View {
        ViewThatFits(in: .horizontal) {
            sideBySide
                .frame(minWidth: sideBySideWidth, idealWidth: sideBySideWidth, maxWidth: .infinity)
            stacked
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A fixed fill rather than `.fill.quaternary`, which resolves
        // against the foreground style, and comes out lighter inside a
        // `Menu` label (the navigate tile's, with several maps apps).
        .background(Color(uiColor: .quaternarySystemFill), in: Self.shape)
        .contentShape(Self.shape)
    }

    private var sideBySide: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 24)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }

    private var stacked: some View {
        VStack(spacing: 4) {
            icon
                .frame(height: 24)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                // Room for two lines even for a one-line title, so every
                // stacked tile is the same height.
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(tint)
    }
}

/// Shades a tile while it is pressed, the way a list row highlights.
private struct SheetActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                in: SheetActionTile.shape
            )
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
        HStack(spacing: SheetLayout.iconSpacing) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: SheetLayout.iconColumn)
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
    /// Diameter of the sheet's row buttons — a system glass button's
    /// (the size of the toolbar's settings button on the same screen).
    static let standardDiameter: CGFloat = 44
    /// How far the tap target reaches past the circle on every side:
    /// half the gap between two rows' buttons, so stacked targets meet
    /// without overlapping. The label is laid out at this larger size;
    /// whoever places the button takes the outset back off with a
    /// negative padding, so layout still goes by the circle. (It has
    /// to be the placer: a `Menu`'s touch area is its label's frame.)
    static let tapOutset: CGFloat = SheetLayout.rowSpacing / 2

    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = standardDiameter

    var body: some View {
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
        .frame(width: diameter, height: diameter)
        // Raised system-style glass button — the same neutral glass
        // circle as the close / share buttons on the Apple Maps
        // place sheet, with the state color carried by the symbol
        // (red stop / green unlock) rather than a tinted fill.
        // `.interactive()` gives the native press bounce + shimmer.
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(Self.tapOutset)
        .contentShape(Rectangle())
    }
}

/// Convenience Button wrapper around `CircularIconLabel` for cases
/// without a long-press menu (refresh, lock).
struct CircularIconButton: View {
    let systemName: String
    let tint: Color
    var isBusy: Bool = false
    var diameter: CGFloat = CircularIconLabel.standardDiameter
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
        .padding(-CircularIconLabel.tapOutset)
    }
}

// MARK: - Sheet chrome

private extension UIColor {
    /// Fill of a fully expanded card — what a system sheet uses: the
    /// plain background in light mode, the elevated one in dark mode
    /// (a card over a dark map shouldn't go pure black).
    static let sheetBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
    }
}


/// Clips a glass card and draws its edge the way a system sheet does.
///
/// A stock sheet floating over a map (`UISheetPresentationController`,
/// iOS 26–27, measured from screenshots) has no light rim and casts no
/// shadow. Its glass catches a highlight along the top and bottom
/// edges — `glassEffect` draws the same — and its left and right edges
/// get a hairline of black just outside them that fades out around the
/// corners: about half a point, 68% black in dark mode and 39% in
/// light, where it also runs faintly along the top and bottom. Once a
/// sheet fills the window its edges are bare, so the hairline fades
/// out with `floating`.
private struct SheetChrome<S: Shape>: ViewModifier {
    let shape: S
    /// 1 while the card floats over the map, 0 once it has become a
    /// full-window sheet.
    var floating: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    /// How far along each end the hairline takes to fade, about a top
    /// corner's height.
    private let cornerFade: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .background {
                if floating > 0 {
                    hairline.opacity(floating)
                }
            }
    }

    private var hairline: some View {
        let isDark = colorScheme == .dark
        // Strength along the top and bottom edges, relative to the
        // sides.
        let ends = isDark ? 0 : 0.25
        return shape
            .stroke(.black.opacity(isDark ? 0.68 : 0.39), lineWidth: 1)
            // The stroke straddles the edge: keep only its outer half.
            .mask {
                ZStack {
                    Rectangle().padding(-2)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .mask {
                GeometryReader { geo in
                    let fade = min(cornerFade / max(geo.size.height, 1), 0.5)
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(ends), location: 0),
                            .init(color: .black, location: fade),
                            .init(color: .black, location: 1 - fade),
                            .init(color: .black.opacity(ends), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                // Reach the part of the line outside the top and
                // bottom edges.
                .padding(-2)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Scroll-driven expansion support

/// A card's scroll position, in an object of its own: bound through
/// `Bindable`, setting it — every frame of a spring — redraws only the
/// ScrollView. Held in a `@State`, it would redraw the whole card.
@Observable
private final class ScrollPositionBox {
    var position = ScrollPosition(edge: .top)
}

/// Binds a ScrollView's position to a `ScrollPositionBox` from a
/// modifier of its own, so that the position changing redraws this
/// modifier rather than the view it is attached to.
private struct BoxedScrollPosition: ViewModifier {
    let box: ScrollPositionBox

    func body(content: Content) -> some View {
        content.scrollPosition(Bindable(box).position)
    }
}

/// The cards' live inner-ScrollView offsets, per VIN, which
/// `VehicleSheetPager` turns into their heights. An object the cards
/// report into rather than a binding to the pager's state: a binding
/// into state that changes every frame counts as changed for every
/// card, and would redraw the cards that aren't moving along with the
/// one that is.
@Observable
final class SheetScrollOffsets {
    private var offsets: [String: CGFloat] = [:]

    subscript(vin: String) -> CGFloat { offsets[vin] ?? 0 }

    /// Records a card's offset — to the half point, and only once it has
    /// moved by more than a quarter of one: finer steps would only redraw
    /// the pager for no visible change.
    func report(_ offset: CGFloat, for vin: String) {
        let rounded = (offset * 2).rounded() / 2
        guard abs((offsets[vin] ?? 0) - rounded) > 0.25 else { return }
        // The offset is already animated by whatever scrolled it.
        // Applied inside an animated scroll's transaction the card's
        // frame would be animated a second time, on top — trailing its
        // own content, then springing past its expanded height.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offsets[vin] = rounded
        }
    }
}

/// Where a card's inner ScrollView is right now, for
/// `DetentSnapBehavior`: a target behavior is told where a gesture
/// began and where it would come to rest, but not where the scroll is
/// as the finger lifts. A reference rather than a value so that
/// keeping it current doesn't hand the ScrollView a new behavior every
/// frame.
private final class ScrollOffsetTracker {
    var offset: CGFloat = 0
    /// The speed (points per second, positive raising the card) of the
    /// drag that just ended, kept from `DetentSnapBehavior` until the
    /// card springs off at it.
    var releaseVelocity: CGFloat = 0
    /// Whether `DetentSnapBehavior` stopped the drag that just ended
    /// for the card to spring from.
    var isSnapPending = false
    /// True from the moment the card starts scrolling itself (springing
    /// to a detent) until a finger next takes over. The target behavior
    /// is consulted on those scrolls too, and must leave them alone.
    var isScrollingInCode = false
    /// The scroll's phase as last reported. A scroll no finger is on —
    /// the status bar's scroll-to-top, a pointer's scroll wheel — may
    /// not report one at all, and leaves this `.idle`.
    var phase: ScrollPhase = .idle
    /// The card's current `expansionTravel`, for work that outlives the
    /// view value that started it (a spring's completion, a delayed
    /// check).
    var travel: CGFloat = 0
    /// The pending check that the card has come to rest at a detent
    /// (see the card's `settleWhenStill(at:)`).
    var settleCheck: Task<Void, Never>?
    /// Where the card was last found resting between its detents, and how
    /// many springs from that same spot have failed to move it.
    var settleOffset: CGFloat = .nan
    var settleRetries = 0
}

/// A released drag's way to a detent: the offset it comes to rest at
/// and the spring that takes it there. The numbers are a system
/// sheet's (`UISheetPresentationController`, iOS 26–27). Apple doesn't
/// publish them; they were measured by driving a stock sheet with
/// synthesized drags and logging its position every frame.
private struct SheetSnap {
    /// Release speed, in points per second, at and above which a drag
    /// is a flick: the card goes on to the next detent in the flick's
    /// direction wherever it was let go, and arrives with a little
    /// overshoot (`flickSpring`).
    static let flickVelocity: CGFloat = 1000
    /// A slower release is carried on by this many seconds of its
    /// speed, less the first `velocityDeadZone`, and then settles at
    /// whichever detent the carried-on offset is nearer. A gentle
    /// release therefore goes to the nearer detent, and it takes a
    /// fairly brisk one to carry the card over the midpoint from far
    /// short of it.
    static let projectionTime: CGFloat = 0.13
    static let velocityDeadZone: CGFloat = 130
    /// The spring every detent change runs on, released or
    /// programmatic. Critically damped, so the card stops at the
    /// detent without bouncing.
    static let spring = Spring(response: 0.344, dampingRatio: 1)
    /// A flick's: the same stiffness, a little underdamped.
    static let flickSpring = Spring(response: 0.344, dampingRatio: 0.8)

    /// Offset the card comes to rest at: 0 (collapsed) or `travel`.
    let offset: CGFloat
    /// Release velocity along the scroll, in points per second;
    /// positive raises the card.
    let velocity: CGFloat

    /// Where a drag released at `released`, moving at `velocity`
    /// (points per second, positive raising the card), comes to rest.
    init(released: CGFloat, velocity: CGFloat, travel: CGFloat) {
        let speed = abs(velocity)
        let expands: Bool
        if speed >= Self.flickVelocity {
            expands = velocity > 0
        } else {
            let carry = Self.projectionTime * max(0, speed - Self.velocityDeadZone)
            expands = released + (velocity < 0 ? -carry : carry) >= travel / 2
        }
        self.offset = expands ? travel : 0
        self.velocity = velocity
    }

    var spring: Spring {
        abs(velocity) >= Self.flickVelocity ? Self.flickSpring : Self.spring
    }
}

/// Springs a card's scroll to a detent, setting the offset every frame
/// from the spring's equation.
///
/// SwiftUI follows a spring when it animates a scroll, but only from
/// rest: a scroll animation can't be handed the speed the finger let go
/// at (`interpolatingSpring`'s initial velocity and custom animations
/// are ignored for scrolls — measured, they ran on SwiftUI's own
/// curves). A card let go mid-flick would stop dead under the finger
/// and then set off again. Driven here, it carries on at the finger's
/// speed, as a system sheet does.
@MainActor
private final class SheetSpringDriver: NSObject {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var velocity: CGFloat = 0
    private var spring = SheetSnap.spring
    private var duration: TimeInterval = 0
    private var apply: (CGFloat) -> Void = { _ in }
    private var completion: () -> Void = {}

    var isRunning: Bool { link != nil }

    /// Springs from `from` to `to`, starting at `velocity` (points per
    /// second), handing each frame's offset to `apply`. `takingOver`
    /// moves the scroll to `from` straight away, to stop the momentum of
    /// a scroll that is still coasting; a scroll at rest is left alone
    /// until the first frame (moving it to where it already is would
    /// only cost the frame that starts the spring a redraw).
    func run(
        from: CGFloat,
        to: CGFloat,
        velocity: CGFloat,
        spring: Spring,
        takingOver: Bool,
        apply: @escaping (CGFloat) -> Void,
        completion: @escaping () -> Void
    ) {
        stop()
        self.from = from
        self.to = to
        self.velocity = velocity
        self.spring = spring
        self.apply = apply
        self.completion = completion
        duration = spring.settlingDuration(
            target: Double(to - from),
            initialVelocity: Double(velocity),
            epsilon: 0.1
        )
        // Nothing to animate (or no finite time to do it in): arrive now
        // rather than run a display link that never reaches its end.
        guard duration.isFinite, duration > 0 else {
            apply(to)
            completion()
            return
        }
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        if takingOver { apply(from) }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // The time this frame will be on screen.
        let time = link.targetTimestamp - start
        guard time < duration else {
            stop()
            apply(to)
            completion()
            return
        }
        let travelled = spring.value(target: Double(to - from), initialVelocity: Double(velocity), time: time)
        guard travelled.isFinite else {
            stop()
            apply(to)
            completion()
            return
        }
        apply(from + CGFloat(travelled))
    }
}

/// Decides where a released scroll comes to rest, around the card's
/// two detents — collapsed at offset 0, expanded at `travel`.
///
/// Released partway through the travel, the card never coasts there:
/// the scroll stops where the finger let go, and the card springs on
/// to whichever detent `SheetSnap` picks, as a system sheet does (see
/// the card's `onScrollPhaseChange`). A scroll view's own
/// deceleration, retargeted to a detent, would crawl the last stretch.
///
/// The expanded detent stops momentum, as it does on a system sheet:
/// a flick released in scrolled content runs back to the top of the
/// content and leaves the card expanded instead of carrying on into a
/// collapse. A finger still on the screen is not stopped: it can drag
/// through the detent either way. Released in the content, the scroll
/// decelerates naturally.
private struct DetentSnapBehavior: ScrollTargetBehavior {
    let travel: CGFloat
    let tracker: ScrollOffsetTracker

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard !tracker.isScrollingInCode else { return }
        tracker.isSnapPending = false
        // The context's velocity is in points per millisecond.
        tracker.releaseVelocity = context.velocity.dy * 1000
        guard travel > 1 else { return }
        // Can trail the scroll by a frame — a fast flick can start and
        // end between two — so it only sorts the release here. The card
        // springs from where the scroll really is (see the card's
        // `onScrollPhaseChange`).
        let released = tracker.offset
        if released >= travel - 0.5 {
            if target.rect.origin.y < travel { target.rect.origin.y = travel }
            return
        }
        // Pulled down below the collapsed detent and let go: the
        // scroll's own bounce brings it back.
        guard released > 0 || target.rect.origin.y > 0 else { return }
        tracker.isSnapPending = true
        target.rect.origin.y = released
    }
}

// MARK: - Height preference keys

/// Measures the height of just the controls section (header, ranges,
/// lock, climate). A backstop for the collapsed height: the pager
/// sizes every collapsed card from `ControlsSizingTemplate`, but
/// never lets it be shorter than a vehicle's real controls — whatever
/// the template failed to anticipate (a wrapped line, a new row).
private struct ControlsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Measures how tall a card's content is laid out — every section, plus
/// the margin that keeps its end clear of the home indicator. The pager
/// stops the expanded card there: a vehicle whose content fits on screen
/// gets a card just tall enough for it, not one that runs on to the top
/// of the window with nothing in it.
private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey reporting the height taken up by the optional error
/// card above the main card (its outer height, including the gap
/// below it). The pager adds the selected card's to its ScrollView
/// frame so the error card fits without being clipped. Reports 0
/// when no error is present.
///
/// Crucially, this measures ONLY the error card itself — NOT the
/// total page including the main card. The main card's height
/// changes every frame during a drag, so measuring the whole page
/// would cascade `cardHeight` → measurement → pager height →
/// re-layout per drag tick, producing visible judder. Measuring
/// just the (drag-independent) error overhead breaks that loop.
private struct ErrorOverheadPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Dictionary where Value: Hashable {
    /// `self[key, default: fallback]` in a form a key path can hold: the
    /// standard library's takes its default as a closure, which can't be
    /// a key path's subscript argument.
    subscript(_ key: Key, fallback fallback: Value) -> Value {
        get { self[key] ?? fallback }
        set { self[key] = newValue }
    }
}

// MARK: - Vehicle sheet pager

/// Horizontal paging container for one `PersistentVehicleSheet` per
/// vehicle. Owns each card's detent and scroll offset and turns them
/// into the card's geometry (`cardLayout(for:geo:)`): every card
/// collapses to the same height and expands to fill the window.
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
    /// Bottom inset the map should keep clear of the sheet. While
    /// the card spans the full window width this is the distance
    /// from the bottom of the screen to the visible top edge of a
    /// *collapsed* card, so `MainView` can inset the map's safe area
    /// and MapKit centers the vehicle marker in the area above the
    /// card. Once the window is wide enough that a marker centered
    /// in the whole frame clears the card horizontally (see
    /// `markerClearsSheet`), this is 0 and the marker is centered in
    /// the frame instead.
    @Binding var mapBottomInset: CGFloat
    /// True while a card stands over the settings button in the
    /// toolbar's trailing corner, so `MainView` can fade the button
    /// out: the card's rounded corner would otherwise leave a slice of
    /// it showing, out of reach behind the sheet.
    @Binding var coversToolbar: Bool
    /// Whether a card can rise over the toolbar's trailing item at all
    /// in this window (see `cardsCanCoverToolbar(geo:)`). Where it
    /// can't, `MainView` leaves the settings button in the toolbar.
    @Binding var canCoverToolbar: Bool

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

    /// Binding handed to each card so its drag handle tap and any
    /// other detent writes land in the per-vehicle slot rather
    /// than a single shared value. A key path into `detents` rather
    /// than a `Binding(get:set:)`: SwiftUI can tell that one is
    /// unchanged from frame to frame, and so skips the cards that
    /// aren't moving when the pager redraws for one that is. Built
    /// from fresh closures, every card would be redrawn every frame.
    private func detentBinding(for vin: String) -> Binding<SheetDetent> {
        $detents[dynamicMember: \.[vin, fallback: .collapsed]]
    }
    /// Per-VIN live inner-ScrollView offset, reported by each card.
    /// Drives each card's height (see `cardLayout(for:geo:)`).
    @State private var scrollOffsets = SheetScrollOffsets()
    /// Per-VIN error-card overhead (errorCardView outer height,
    /// including the gap under it). Stable measurement — doesn't
    /// change with `cardHeight` during drags. The pager adds the
    /// selected card's to its frame so the error card fits above the
    /// main card without clipping.
    @State private var errorOverheads: [String: CGFloat] = [:]
    /// Per-VIN controls-section height (header + ranges + lock +
    /// climate, measured by `ControlsHeightPreferenceKey`). Only a
    /// floor under `collapsedCardHeight`.
    @State private var controlsHeights: [String: CGFloat] = [:]
    /// Per-VIN height of the card's content (measured by
    /// `ContentHeightPreferenceKey`), which caps how tall the card grows.
    @State private var contentHeights: [String: CGFloat] = [:]
    /// Height of `ControlsSizingTemplate` — the tallest controls
    /// section any vehicle can have — which sets the collapsed height
    /// of every card.
    @State private var templateControlsHeight: CGFloat = 0
    /// True while a swipe has the pager between pages (dragging or
    /// settling).
    @State private var isPaging = false

    /// Floor for the collapsed detent — used until the controls
    /// measurements arrive on first render so the card doesn't
    /// briefly flash at 0 height.
    private let collapsedHeightFloor: CGFloat = 200
    /// Less room than this above a collapsed card and it doesn't get
    /// an expanded detent at all: the card stays put and its content
    /// scrolls in place.
    private let minimumExpansionTravel: CGFloat = 44
    /// How far below the status bar an expanded card stops. It must
    /// not be 0: a ScrollView whose frame so much as TOUCHES a
    /// safe-area edge is handed that edge's inset as a content inset
    /// and extended under the bar. For a card arriving at the status
    /// bar that knocks its scroll offset — which is its height — back
    /// by the inset, the card drops, the inset goes away, the snap
    /// resumes… and the card saws up and down short of its detent.
    /// Stopping a hair short keeps every ScrollView in here clear of
    /// the edge. (Ignoring the safe area further up doesn't help;
    /// the inset is then measured to the screen edge instead.)
    private let statusBarGap: CGFloat = 2
    /// Gap between a collapsed card and the page's side and bottom
    /// edges (`PersistentVehicleSheet.outerInset`).
    private let cardOuterInset: CGFloat = 8
    /// Share of a card's bounce, pulled down past its collapsed detent,
    /// that comes off its height. The bounce alone resists the finger too
    /// little to read as "this is as low as it goes": rubber-banded
    /// against the inner ScrollView's full expanded height, it lets a
    /// 200pt pull take some 80pt off a card that is only ~350pt tall.
    private let pullDownGive: CGFloat = 0.5
    /// Size of the corner of the window the settings button lives in,
    /// measured from the top of the safe area and from the trailing
    /// edge. A card whose top comes within this of its highest
    /// position, in a pager that reaches this close to the trailing
    /// edge, is over the button.
    private let toolbarItemReach = CGSize(width: 64, height: 64)
    /// Widest the pager (and therefore each card) will grow. Below
    /// this the card fills the window edge-to-edge; above it the
    /// card stops growing and stays pinned to the leading edge,
    /// Apple-Maps-sidebar style. A continuous cap rather than a
    /// size-class switch, so resizing a window (iPad windowing,
    /// Stage Manager, Mac) never snaps the card between two widths.
    /// 440pt is the widest iPhone portrait width (Pro Max), so every
    /// iPhone keeps its full-bleed card in portrait.
    private let maxSheetWidth: CGFloat = 440
    /// Horizontal room the vehicle marker needs on either side of
    /// its center: half the 50pt marker circle plus the widest
    /// display-name label that hangs below it. Used to decide when
    /// a frame-centered marker is clear of the card.
    private let markerClearance: CGFloat = 80

    /// Width of the pager and of every card in it: the window
    /// width up to `maxSheetWidth`. Computed from the
    /// GeometryReader rather than via `containerRelativeFrame`
    /// because the latter resolves against the ScrollView's
    /// container a layout pass late — during a live window resize
    /// the card's trailing edge visibly trailed and bounced behind
    /// the pane edge. Explicit widths derived from `geo` resolve
    /// synchronously, so the card tracks the pane like a plain view.
    private func pageWidth(geo: GeometryProxy) -> CGFloat {
        max(0, min(maxSheetWidth, geo.size.width))
    }

    /// True when the cap has kicked in and the pager is a column on
    /// the leading side of a wider window.
    private func isWidthCapped(geo: GeometryProxy) -> Bool {
        geo.size.width > maxSheetWidth
    }

    /// True when a marker centered in the full frame would sit
    /// entirely to the right of the card (card width + its outer
    /// inset + `markerClearance`). Below this the map is inset so
    /// the marker rides above the card; at or above it the marker
    /// is simply centered in the frame.
    private func markerClearsSheet(geo: GeometryProxy) -> Bool {
        let sheetRightEdge = min(maxSheetWidth, geo.size.width) + cardOuterInset
        return geo.size.width / 2 - markerClearance > sheetRightEdge
    }

    /// Height the sheet has to work with: from the top of the safe
    /// area (the bottom of the status bar) down to the physical
    /// bottom of the window. `geo` itself stops at the bottom safe
    /// area; the cards are laid out through it (see `body`).
    private func areaHeight(geo: GeometryProxy) -> CGFloat {
        geo.size.height + geo.safeAreaInsets.bottom
    }

    /// Space left between the top of the safe area and a fully
    /// expanded card. Normally just `statusBarGap`: the card rises to
    /// the bottom of the status bar, like a system sheet. A window
    /// with controls in its top-leading corner (iPadOS windowing)
    /// keeps the card below them, and a window with no status bar at
    /// all (iPhone landscape) keeps a small gap rather than letting
    /// the card touch its edge.
    private func topClearance(geo: GeometryProxy) -> CGFloat {
        max(
            geo.containerCornerInsets.topLeading.height,
            geo.safeAreaInsets.top > 0 ? statusBarGap : cardOuterInset
        )
    }

    /// Whether an expanded card grows out to the page's side and
    /// bottom edges. Not where the page itself stops short of the
    /// window's edge (iPhone landscape, beside the sensor housing) —
    /// a card docked against nothing would just look cut off, so
    /// there it stays a floating card and only gains height.
    private func expandsEdgeToEdge(geo: GeometryProxy) -> Bool {
        geo.safeAreaInsets.leading == 0
    }

    /// Whether the window shows anything beside the pager: open map past
    /// a width-capped column, or a strip outside the safe area (iPhone
    /// Duo's status column). A neighbouring card would be on screen
    /// there, so cards fade as they page instead of sliding in whole.
    private func showsBesidePager(geo: GeometryProxy) -> Bool {
        isWidthCapped(geo: geo) || geo.safeAreaInsets.leading > 0 || geo.safeAreaInsets.trailing > 0
    }

    /// Whether a card can rise over the toolbar's trailing item at all:
    /// the pager reaches to within `toolbarItemReach` of the window's
    /// trailing edge. Not a column beside open map, and not where the
    /// toolbar has a column of its own beside the pager (iPhone Duo's
    /// side toolbar, in the trailing safe area).
    private func cardsCanCoverToolbar(geo: GeometryProxy) -> Bool {
        pageWidth(geo: geo) > geo.size.width + geo.safeAreaInsets.trailing - toolbarItemReach.width
    }

    var body: some View {
        GeometryReader { geo in
            // The pager's frame hugs the SELECTED card (plus its error
            // card), not the tallest card in the row. An expanded card
            // fills the window, and a frame sized for one would go on
            // swallowing map taps after the user pages to a collapsed
            // neighbour. A taller neighbour just overflows the top of
            // the frame — the pager doesn't clip — which only shows
            // mid-swipe, when it has no need to be touchable.
            let pagerHeight = currentVin.map {
                cardLayout(for: $0, geo: geo).top + (errorOverheads[$0] ?? 0)
            } ?? 0
            // Hold the last reported inset while `geo` is degenerate
            // (the zero-height first layout pass) instead of reporting
            // a collapsed height clamped to ~0 from it — the map would
            // briefly center the marker behind the card.
            let bottomInset: CGFloat = if areaHeight(geo: geo) < collapsedHeightFloor {
                mapBottomInset
            } else if markerClearsSheet(geo: geo) {
                0
            } else {
                collapsedSheetTop(geo: geo)
            }
            let coversToolbarNow = cardsCoverToolbar(geo: geo)
            let canCoverToolbarNow = cardsCanCoverToolbar(geo: geo)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                pagerScrollView(geo: geo, pageWidth: pageWidth(geo: geo), height: pagerHeight)
                    // Cap the pager width so the cards don't stretch
                    // across a wide window. Explicit width (not
                    // `maxWidth`) so it resolves in the same layout
                    // pass as the GeometryReader — see `pageWidth`.
                    .frame(width: pageWidth(geo: geo), height: pagerHeight)
                    // Pin to the leading edge once the cap kicks in
                    // (no-op below it, where the frame already fills).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // No animation when `selectedVehicleIndex`
                    // changes — the pager frame should just BE the
                    // new card's size on the next render, not
                    // spring-animate into place after the swipe
                    // settles (which reads as a distracting
                    // post-swipe bounce).
                    .animation(nil, value: selectedVehicleIndex)
            }
            // Extend through the bottom safe area so a collapsed
            // card's outer edge sits the same 8pt off the physical
            // screen on its sides and bottom, and an expanded one runs
            // off the bottom of the screen. Respecting the safe area
            // instead leaves the ~34pt home-indicator strip below the
            // card, which makes the *outer* bottom gap (card → screen
            // edge) read as much larger than the left/right gap. This
            // is the gap the user measures visually, so it has to
            // match.
            // (Ignored here rather than on the GeometryReader so
            // `geo` still reports the inset — the cards need it.)
            .ignoresSafeArea(.container, edges: .bottom)
            .onChange(of: bottomInset, initial: true) { old, new in
                guard mapBottomInset != new else { return }
                // Animate only the above-card ↔ frame-centered mode
                // flip (a window resize crossing the clearance
                // threshold). Measurement-driven height changes at
                // launch stay instant so the map doesn't slide
                // around while the card is still sizing itself.
                if (old == 0) != (new == 0) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        mapBottomInset = new
                    }
                } else {
                    mapBottomInset = new
                }
            }
            .onChange(of: coversToolbarNow, initial: true) { _, new in
                guard coversToolbar != new else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    coversToolbar = new
                }
            }
            .onChange(of: canCoverToolbarNow, initial: true) { _, new in
                if canCoverToolbar != new { canCoverToolbar = new }
            }
        }
        // A keyboard (some other sheet's) must not squeeze the pager.
        .ignoresSafeArea(.keyboard)
        // Laid out, never drawn — see `ControlsSizingTemplate`.
        .background {
            ControlsSizingTemplate()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    (proxy.size.height * 2).rounded() / 2
                } action: { height in
                    templateControlsHeight = height
                }
                .hidden()
        }
    }

    /// Height of every collapsed card: enough for the tallest set of
    /// main controls any vehicle can show (`templateControlsHeight`),
    /// so the collapsed detent is one fixed height rather than a
    /// function of whichever vehicle is on screen. The vehicles'
    /// measured controls are only a backstop — if a card's real
    /// controls ever outgrow the template, they still fit.
    private var collapsedCardHeight: CGFloat {
        let measured = bbVehicles.compactMap { controlsHeights[$0.vin] }.max() ?? 0
        let controls = max(templateControlsHeight, measured)
        // The controls (their height includes the header's top margin)
        // plus the space kept under them at the fold. Floor protects
        // against the first render before measurement.
        return max(
            collapsedHeightFloor,
            controls > 0 ? controls + SheetLayout.foldMargin : 0
        ).rounded()
    }

    /// Distance from the physical bottom of the screen to the
    /// visible top edge of a collapsed card: the collapsed card
    /// frame plus the 8pt outer inset below it. Ignores the live
    /// scroll and the card's actual detent. The transient error card
    /// above the main card is deliberately NOT included — it would
    /// shift the map every time an error appeared or cleared.
    private func collapsedSheetTop(geo: GeometryProxy) -> CGFloat {
        min(
            collapsedCardHeight + cardOuterInset,
            max(0, areaHeight(geo: geo) - topClearance(geo: geo))
        )
    }

    /// One card's geometry for its current scroll offset.
    private struct CardLayout {
        /// Height of the card's frame.
        let cardHeight: CGFloat
        /// Gap between the card and the page's side and bottom edges.
        let edgeInset: CGFloat
        /// How far the card's top edge rises between collapsed and
        /// expanded; 0 when the card can't expand.
        let travel: CGFloat
        /// Height of the card's frame once fully expanded.
        let expandedHeight: CGFloat
        /// How far along `travel` the card is: 0 collapsed, 1
        /// expanded.
        let progress: CGFloat
        /// Distance left between the card's top edge and the ceiling —
        /// the highest any card may go, whether or not this one goes
        /// that far.
        let headroom: CGFloat

        /// Distance from the bottom of the window to the card's top
        /// edge.
        var top: CGFloat { cardHeight + edgeInset }
    }

    /// Per-vehicle card geometry. Every card rests at the same
    /// collapsed height; its inner ScrollView's offset IS the
    /// expansion — the first `travel` points of it raise the card's
    /// top edge from there to the top of the window, or as far as its
    /// content needs if that's less (anything beyond scrolls content),
    /// and over that same stretch the gap around the card closes, so it
    /// lands as an edge-to-edge sheet. Pulled down below collapsed, it
    /// gives way by part of the bounce (`pullDownGive`). Each
    /// card follows ITS OWN offset: swiping between vehicles preserves
    /// whatever expanded/collapsed state the user left them in.
    private func cardLayout(for vin: String, geo: GeometryProxy) -> CardLayout {
        // The highest the card's top edge may go: the bottom of the
        // status bar, less the room an error card needs above it.
        // `geo.size.height` can be 0 (or briefly tiny) on the first
        // GeometryReader pass before layout completes; without the
        // `max(0, …)` clamps a negative height would reach
        // `.frame(height:)` and produce "Invalid frame dimension
        // (negative or non-finite)" runtime warnings.
        let ceiling = max(
            0,
            areaHeight(geo: geo) - topClearance(geo: geo) - (errorOverheads[vin] ?? 0)
        )
        let restingTop = min(collapsedCardHeight + cardOuterInset, ceiling)
        // Fully expanded, the card is as tall as its content — no taller,
        // so content that fits on screen doesn't leave a run of empty
        // card under it — up to the ceiling, past which the content
        // scrolls. (Until the content is measured, up to the ceiling.)
        let edgeToEdge = expandsEdgeToEdge(geo: geo)
        let expandedTop = min(
            ceiling,
            (contentHeights[vin] ?? .infinity) + (edgeToEdge ? 0 : cardOuterInset)
        )
        let room = max(0, expandedTop - restingTop)
        let travel = room >= minimumExpansionTravel ? room : 0
        let scrolled = scrollOffsets[vin]
        let offset = min(max(0, scrolled), travel)
        let progress = travel > 0 ? offset / travel : 0
        let expandedInset = travel > 0 && edgeToEdge ? 0 : cardOuterInset
        let edgeInset = cardOuterInset + (expandedInset - cardOuterInset) * progress
        // Pulled down past the collapsed detent, the card gives way a
        // little: part of the scroll's bounce comes off its top edge, and
        // the bounce's own return springs it back. (The card keeps its
        // content pinned to that edge.)
        let give = min(0, scrolled) * pullDownGive
        // Round to integer points so the card's top edge snaps to
        // pixel boundaries — fractional values cause SwiftUI to
        // re-snap mid-drag, producing visible 1pt judder.
        let top = min((restingTop + offset + give).rounded(), restingTop + travel)
        return CardLayout(
            cardHeight: max(0, top - edgeInset),
            edgeInset: edgeInset,
            travel: travel,
            expandedHeight: max(0, restingTop + travel - expandedInset),
            progress: progress,
            headroom: ceiling - top
        )
    }

    /// Whether a card rests at one of its detents — the only places where
    /// its content width holds still.
    ///
    /// The measured heights (`contentHeights`, `controlsHeights`) are only
    /// taken there. Between the detents the content's width follows
    /// `edgeInset`, which follows the very geometry those heights feed:
    /// a status line that wraps at the collapsed width and not at the
    /// expanded one makes the controls taller → the resting height
    /// greater → the travel shorter → the finger's offset further along
    /// it → the card wider → the line unwraps → the controls shorter → …
    /// With each state undoing the other, SwiftUI lays the card out
    /// round and round, the map re-centres on every pass (the collapsed
    /// height sets `mapBottomInset`), and the app freezes until the
    /// system kills it for memory — with no crash log to show for it.
    /// Taken at rest, a height can't move the width it was measured at.
    private func restsAtDetent(_ vin: String, geo: GeometryProxy) -> Bool {
        let layout = cardLayout(for: vin, geo: geo)
        let scrolled = scrollOffsets[vin]
        return layout.travel <= 0 || scrolled <= 0.5 || scrolled >= layout.travel - 0.5
    }

    /// Whether a card rests at its collapsed detent (or can't expand at
    /// all) — where the controls are at the width the collapsed card
    /// shows them at.
    private func restsCollapsed(_ vin: String, geo: GeometryProxy) -> Bool {
        cardLayout(for: vin, geo: geo).travel <= 0 || scrollOffsets[vin] <= 0.5
    }

    /// Whether a card on screen stands over the settings button: the
    /// selected card — or, mid-swipe, any card, since a neighbour is
    /// then sliding in under the button too — risen to within reach of
    /// the top of the window, in a pager that can get under the button.
    /// Only cards that can come back down count; one stuck at full
    /// height in a tiny window must not take the button away for good.
    private func cardsCoverToolbar(geo: GeometryProxy) -> Bool {
        guard cardsCanCoverToolbar(geo: geo) else { return false }
        return bbVehicles.contains { vehicle in
            guard isPaging || vehicle.vin == currentVin else { return false }
            let layout = cardLayout(for: vehicle.vin, geo: geo)
            return layout.travel > 0 && layout.headroom < toolbarItemReach.height
        }
    }

    /// Instant (non-animated) scroll to the selected page.
    private func resnap(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(selectedVehicleIndex, anchor: .leading)
        }
    }

    /// One card per vehicle, laid out side by side at `pageWidth`.
    @ViewBuilder
    private func cardsRow(geo: GeometryProxy, pageWidth: CGFloat) -> some View {
        let isWidthCapped = isWidthCapped(geo: geo)
        let fadesNeighbours = showsBesidePager(geo: geo)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(bbVehicles.enumerated()), id: \.element.id) { index, vehicle in
                let layout = cardLayout(for: vehicle.vin, geo: geo)
                PersistentVehicleSheet(
                    bbVehicle: vehicle,
                    bbVehicles: bbVehicles,
                    selectedIndex: selectedVehicleIndex,
                    detent: detentBinding(for: vehicle.vin),
                    cardHeight: layout.cardHeight,
                    edgeInset: layout.edgeInset,
                    expansionTravel: layout.travel,
                    expandedHeight: layout.expandedHeight,
                    expansionProgress: layout.progress,
                    isColumn: isWidthCapped,
                    // A column's trailing-bottom corner lands
                    // mid-window, as does that of a card beside a strip
                    // outside the safe area (iPhone Duo's status column),
                    // and a display without a home indicator has square
                    // corners: none of them gives the card's bottom
                    // corners anything to merge into.
                    squaresBottomWhenExpanded: fadesNeighbours || geo.safeAreaInsets.bottom == 0,
                    bottomSafeAreaInset: geo.safeAreaInsets.bottom,
                    scrollOffsets: scrollOffsets,
                    onSuccessfulRefresh: onSuccessfulRefresh,
                    mfaState: mfaState,
                    sheetPresentation: sheetPresentation
                )
                .frame(width: pageWidth)
                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                    // `phase.value` runs -1 (one page left)
                    // → 0 (on page) → 1 (one page right).
                    content
                        .opacity(fadesNeighbours ? 1 - abs(phase.value) : 1)
                }
                .onPreferenceChange(ErrorOverheadPreferenceKey.self) { value in
                    guard value.isFinite else { return }
                    let rounded = (value * 2).rounded() / 2
                    let vin = vehicle.vin
                    if abs((errorOverheads[vin] ?? 0) - rounded) > 0.5 {
                        errorOverheads[vin] = rounded
                    }
                }
                // The content and controls heights are taken only while the
                // card rests at a detent — see `restsAtDetent(_:geo:)`.
                .onPreferenceChange(ContentHeightPreferenceKey.self) { value in
                    guard value.isFinite else { return }
                    let rounded = (value * 2).rounded() / 2
                    let vin = vehicle.vin
                    guard abs((contentHeights[vin] ?? 0) - rounded) > 0.5,
                          restsAtDetent(vin, geo: geo) else { return }
                    contentHeights[vin] = rounded
                }
                .onPreferenceChange(ControlsHeightPreferenceKey.self) { value in
                    guard value.isFinite else { return }
                    let rounded = (value * 2).rounded() / 2
                    let vin = vehicle.vin
                    // Collapsed only: this is the collapsed card's height.
                    guard abs((controlsHeights[vin] ?? 0) - rounded) > 0.5,
                          restsCollapsed(vin, geo: geo) else { return }
                    controlsHeights[vin] = rounded
                }
                .id(index)
            }
        }
    }

    @ViewBuilder
    private func pagerScrollView(
        geo: GeometryProxy,
        pageWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        // ScrollViewReader (+ `.onScrollPhaseChange` for sync)
        // instead of `.scrollPosition(id:)`. The latter's
        // bidirectional binding was interacting badly with the
        // cards' vertical scrolling, causing pages to commit
        // between snap targets. Decoupling read (phase change →
        // index) from write (selection change → scrollTo) breaks
        // that loop.
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
                // Wherever the window shows past the pager's edge (a
                // width-capped card floating over open map, or a strip
                // outside the safe area — `showsBesidePager`), a sliding
                // card with clipping would materialize at a hard edge.
                // Instead the pager is unclipped (see
                // `scrollClipDisabled` below) and each card fades up as
                // it slides in — a page away it's invisible, on-page
                // it's solid. Spanning the window: no fade, the card
                // enters from the window edge.
                cardsRow(geo: geo, pageWidth: pageWidth)
                    .scrollTargetLayout()
                    // The row is as tall as its tallest card, the
                    // pager only as tall as the selected one (see
                    // `body`). Hold the row to the pager's height,
                    // anchored at the bottom, so every card stays
                    // seated on the bottom edge and a taller
                    // neighbour overflows upward.
                    .frame(height: height, alignment: .bottom)
            }
            .scrollTargetBehavior(.paging)
            // Don't clip at the pager's bounds: a neighbour taller
            // than the selected card stands above the pager's frame,
            // and where the window shows past the pager an incoming
            // card should slide in over it rather than appear at the
            // pager's edge. Off-page neighbours are either offscreen
            // (pager spanning the window) or at opacity 0 (the fade),
            // so nothing else shows at rest.
            .scrollClipDisabled()
            .scrollDisabled(bbVehicles.count <= 1)
            .onScrollPhaseChange { old, new, context in
                BBLogger.info(.app, "[SVI] pager scroll phase \(old) → \(new), offsetX=\(context.geometry.contentOffset.x), width=\(context.geometry.containerSize.width)")
                // Only a swipe counts. A programmatic scroll's
                // `.animating` can't be trusted to end: `scrollTo` a
                // page the pager is already on (every settled swipe
                // triggers one, via `selectedVehicleIndex`) enters it
                // and never reports `.idle` again.
                isPaging = new == .interacting || new == .decelerating
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
            // The scroll offset is stored in points, so when the
            // page width changes (window resize, split-view drag,
            // crossing the width cap) the offset no longer lands on
            // a page boundary and the card drifts or gets stuck
            // part-way across. `.paging` only re-snaps after a user
            // scroll, so re-snap on every width change — instantly,
            // so the card tracks the resize instead of springing
            // after it. Keyed on our own `pageWidth` (synchronous
            // with layout); the scroll-geometry hook below catches
            // the case where the content size hadn't grown yet when
            // the first re-snap ran and the offset got clamped.
            .onChange(of: pageWidth) { _, _ in
                resnap(proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.width
            } action: { old, new in
                guard old != new, new > 0 else { return }
                resnap(proxy)
            }
            .onAppear {
                BBLogger.info(.app, "[SVI] pager .onAppear (idx=\(selectedVehicleIndex), count=\(bbVehicles.count))")
                proxy.scrollTo(selectedVehicleIndex, anchor: .leading)
            }
        }
    }
}
