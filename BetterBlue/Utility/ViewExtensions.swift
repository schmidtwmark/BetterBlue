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
        if model.modelContext == nil {
            EmptyView()
        } else {
            content()
        }
    }
}
