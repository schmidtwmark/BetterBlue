//
//  ViewExtensions.swift
//  BetterBlue
//
//  View extensions for consistent styling
//

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
            .glassEffect(.regular, in: shape)
            .clipShape(shape)
    }
}
