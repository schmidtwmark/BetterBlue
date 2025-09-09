//
//  AnimationExtensions.swift
//  BetterBlue
//
//  Created by Mark Schmidt on 9/6/25.
//

import SwiftUI

private enum AnimationKind {
    case spin
    case pulse(range: ClosedRange<Double>)

    var range: ClosedRange<Double> {
        switch self {
        case .spin: 0.0 ... 360.0
        case let .pulse(range): range
        }
    }

    func animation(duration: Double) -> Animation {
        switch self {
        case .spin: .linear(duration: duration).repeatForever(autoreverses: false)
        case .pulse: .easeInOut(duration: duration).repeatForever(autoreverses: true)
        }
    }
}

private struct SingleAnimationModifier: ViewModifier {
    let kind: AnimationKind
    let duration: Double

    init(kind: AnimationKind, duration: Double) {
        self.kind = kind
        self.duration = duration
        _animatedValue = State(initialValue: kind.range.lowerBound)
    }

    @State private var animatedValue: Double

    func body(content: Content) -> some View {
        Group {
            switch kind {
            case .spin:
                content.rotationEffect(.degrees(animatedValue))
            case .pulse:
                content.scaleEffect(animatedValue)
            }
        }
        .onAppear { startAnimation() }
        .animation(animation, value: animatedValue)
    }

    private var animation: Animation {
        kind.animation(duration: duration)
    }

    private func startAnimation() {
        DispatchQueue.main.async {
            animatedValue = kind.range.upperBound
        }
    }
}

public extension View {
    @ViewBuilder func `if`(_ condition: @autoclosure () -> Bool, transform: (Self) -> some View) -> some View {
        if condition() {
            transform(self)
        } else {
            self
        }
    }

    func spin(_ active: Bool, duration: Double = 2.0) -> some View {
        self.if(active, transform: { view in
            view.modifier(SingleAnimationModifier(kind: .spin, duration: duration))
        })
    }

    func pulse(_ active: Bool, duration: Double = 2.0) -> some View {
        self.if(active, transform: { view in
            view.modifier(SingleAnimationModifier(kind: .pulse(range: 1.0 ... 1.4), duration: duration))
        })
    }
}
