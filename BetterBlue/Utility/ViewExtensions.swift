//
//  ViewExtensions.swift
//  BetterBlue
//
//  View extensions for consistent styling
//

import SwiftData
import SwiftUI

/// A simple vertical line shape
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

extension View {
    /// Applies consistent vehicle button card styling with rounded corners using iOS 26 glassEffect
    func vehicleCardGlassEffect(radius: CGFloat = 12.0) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return self
            .containerShape(shape)
            .glassEffect(.regular.interactive(), in: shape)
            .clipShape(shape)
    }
}

// MARK: - Tap targets

enum TapTarget {
    /// Smallest a control's tap target should be in either direction
    /// (the platform guideline for touch).
    static let minimumSize: CGFloat = 44
}

extension View {
    /// Gives a small control a full-size tap target without moving
    /// anything: the view keeps its own size in layout, and a tap
    /// within `TapTarget.minimumSize` of its middle counts as a tap on
    /// it. For controls that are deliberately small on screen — a
    /// section header's text button, an info glyph, a badge — where
    /// growing the control itself would push the layout around it.
    ///
    /// Apply it to the control's LABEL: that is what a button or
    /// navigation link takes its tap target from. A list only delivers
    /// touches inside the row or header a control sits in, so there the
    /// target stops at that edge.
    ///
    /// Not for a `Menu`: a menu is hit by its label's frame, whatever
    /// its content shape, so it needs a label that really is that big.
    func expandedTapTarget() -> some View {
        contentShape(ExpandedTapTargetShape())
    }
}

/// A view's bounds, grown evenly about their center to at least
/// `TapTarget.minimumSize` each way.
private struct ExpandedTapTargetShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(
            dx: min(0, (rect.width - TapTarget.minimumSize) / 2),
            dy: min(0, (rect.height - TapTarget.minimumSize) / 2)
        ))
    }
}

// MARK: - Persistent-model detach guard

/// Wraps a view so its contents are only built when the supplied
/// `@Model` is still attached to a `ModelContext`. After SwiftData
/// deletes a model (e.g. cascade delete when an account is removed),
/// SwiftUI can still re-evaluate a body that captures that model —
/// touching any persisted property in that state traps in
/// `_KKMDBackingData.getValue(forKey:)`. Routing through this view
/// makes the model check happen *before* the content closure runs,
/// so no persisted-property access executes on a detached model.
///
/// Usage:
/// ```swift
/// var body: some View {
///     PersistentModelGuard(model: bbVehicle) {
///         // existing body — can read persisted properties freely
///     }
/// }
/// ```
struct PersistentModelGuard<Content: View, Model: PersistentModel>: View {
    let model: Model
    let content: () -> Content

    init(model: Model, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View {
        // Both checks: a model deleted but not yet saved still has its
        // context (only `isDeleted` says so), and one deleted and saved
        // reads `isDeleted == false` with no context.
        if model.isDeleted || model.modelContext == nil {
            EmptyView()
        } else {
            content()
        }
    }
}
