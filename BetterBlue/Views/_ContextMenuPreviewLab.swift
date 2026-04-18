//
//  _ContextMenuPreviewLab.swift
//  BetterBlue
//
//  Scratchpad to isolate which modifier / arrangement breaks the native
//  iOS press-and-hold context-menu animation (the view should visually
//  "grow" along with its shadow during the hold — currently the shadow
//  grows but the card body stays still).
//
//  Each labelled step below adds ONE thing on top of the previous one.
//  Run the Xcode preview and press-and-hold each row in turn; the first
//  variant that fails to grow identifies the culprit.
//
//  This file is diagnostic scaffolding — delete once the root cause is
//  fixed.
//

import SwiftUI

private struct SampleMenu: View {
    var body: some View {
        Group {
            Button("Lock") {}
            Button("Unlock") {}
            Button("Start Climate") {}
        }
    }
}

private struct Variant<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Variants

/// 1. Baseline: bare `Button` + `.contextMenu`. No styling at all.
///    Expected: the text "Tap or hold" visibly scales up during the hold.
private struct V1_Baseline: View {
    var body: some View {
        Variant(label: "1. bare Button + .contextMenu") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
            }
            .contextMenu { SampleMenu() }
        }
    }
}

/// 2. Same as #1 but with `.buttonStyle(.plain)` — which strips the
///    default system button tint/press feedback. Some styles suppress the
///    grow animation; this checks that.
private struct V2_PlainStyle: View {
    var body: some View {
        Variant(label: "2. + .buttonStyle(.plain)") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
            }
            .buttonStyle(.plain)
            .contextMenu { SampleMenu() }
        }
    }
}

/// 3. Add a coloured `.background` to confirm the background scales with
///    the label during the preview grow.
private struct V3_Background: View {
    var body: some View {
        Variant(label: "3. + .background(fill)") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .contextMenu { SampleMenu() }
        }
    }
}

/// 4. Replace the simple background with the project's `.glassEffect(...)`
///    directly. If THIS is the first variant that fails to scale, the
///    glass effect is the culprit.
private struct V4_GlassEffectDirect: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Variant(label: "4. + .glassEffect() directly") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: shape)
            .contextMenu { SampleMenu() }
        }
    }
}

/// 5. Use the project's wrapper `.vehicleCardGlassEffect()` which adds
///    `.containerShape` and `.clipShape` on top of `.glassEffect`. If #4
///    worked and this fails, one of those extra modifiers is the culprit.
private struct V5_VehicleCardGlassEffect: View {
    var body: some View {
        Variant(label: "5. + .vehicleCardGlassEffect()") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .vehicleCardGlassEffect()
            .contextMenu { SampleMenu() }
        }
    }
}

/// 6. Move the styling INSIDE the label (the shape we had before the most
///    recent refactor). Expected: shadow grows, card body does not —
///    reproducing the bug the user is currently seeing.
private struct V6_StylingInsideLabel: View {
    var body: some View {
        Variant(label: "6. styling inside Button label (the broken layout)") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .vehicleCardGlassEffect()
            }
            .buttonStyle(.plain)
            .contextMenu { SampleMenu() }
        }
    }
}

/// 7. Variant #5 plus a fixed outer frame height matching the real
///    buttons (52pt). The outer frame can interact with contextMenu's
///    snapshot size calculation.
private struct V7_OuterFrame: View {
    var body: some View {
        Variant(label: "7. + outer .frame(height: 52)") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .frame(height: 52)
            .vehicleCardGlassEffect()
            .contextMenu { SampleMenu() }
        }
    }
}

/// 8. HStack of TWO variant-5 buttons, matching the real layout.
///    contextMenu on siblings inside an HStack sometimes renders oddly.
private struct V8_HStackOfTwo: View {
    var body: some View {
        Variant(label: "8. HStack of two styled buttons") {
            HStack(spacing: 8) {
                Button {} label: {
                    Text("Left")
                        .padding()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .vehicleCardGlassEffect()
                .contextMenu { SampleMenu() }

                Button {} label: {
                    Image(systemName: "bolt.fill")
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .vehicleCardGlassEffect()
                .contextMenu { SampleMenu() }
            }
        }
    }
}

/// 9. Same as #5 but with an explicit `preview:` view handed to
///    `.contextMenu`. Handing SwiftUI the preview manually bypasses the
///    automatic snapshot path entirely, so if this scales correctly we
///    know the snapshot is what's busted.
private struct V9_ExplicitPreview: View {
    var body: some View {
        Variant(label: "9. + explicit preview: in contextMenu") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .vehicleCardGlassEffect()
            .contextMenu {
                SampleMenu()
            } preview: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: 320)
                    .vehicleCardGlassEffect()
            }
        }
    }
}

/// 10. Drop `.buttonStyle(.plain)` so the system button style runs. Some
///    system styles handle the contextMenu preview differently.
private struct V10_NoPlainStyle: View {
    var body: some View {
        Variant(label: "10. remove .buttonStyle(.plain)") {
            Button {} label: {
                Text("Tap or hold")
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .vehicleCardGlassEffect()
            .contextMenu { SampleMenu() }
        }
    }
}

/// 11. Variant #5 wrapped in a `GlassEffectContainer` (matching what
///    `VehicleCardView` does). The container coordinates glass rendering
///    across its children, so the glass surface is technically drawn by
///    the PARENT. Suspected root cause of the real bug: `.contextMenu`'s
///    snapshot captures the child without its container-rendered glass,
///    so the scaled preview shows stationary glass around a growing body
///    (or vice versa).
private struct V11_InsideGlassEffectContainer: View {
    var body: some View {
        Variant(label: "11. #5 inside GlassEffectContainer") {
            GlassEffectContainer {
                Button {} label: {
                    Text("Tap or hold")
                        .padding()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .vehicleCardGlassEffect()
                .contextMenu { SampleMenu() }
            }
        }
    }
}

/// 12. Like #11 but with several siblings inside the container, more
///    closely matching the actual layout of `VehicleCardView`.
private struct V12_ContainerWithSiblings: View {
    var body: some View {
        Variant(label: "12. GlassEffectContainer with multiple siblings") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Button {} label: {
                        Text("Top")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .vehicleCardGlassEffect()
                    .contextMenu { SampleMenu() }

                    Button {} label: {
                        Text("Middle - hold me")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .vehicleCardGlassEffect()
                    .contextMenu { SampleMenu() }

                    Button {} label: {
                        Text("Bottom")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .vehicleCardGlassEffect()
                    .contextMenu { SampleMenu() }
                }
            }
        }
    }
}

// MARK: - Workaround attempts (all live inside a GlassEffectContainer)

/// W1. Inside an outer `GlassEffectContainer`, wrap the button in its OWN
///    inner `GlassEffectContainer`. The idea: the inner container
///    "catches" this button's glass so the outer one doesn't try to
///    coordinate it, which should let the contextMenu snapshot include
///    the fully-rendered glass surface.
private struct W1_NestedContainer: View {
    var body: some View {
        Variant(label: "W1. nested GlassEffectContainer per button") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Text("Normal sibling (no interaction)")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .vehicleCardGlassEffect()

                    GlassEffectContainer {
                        Button {} label: {
                            Text("Tap or hold — nested container")
                                .padding()
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .vehicleCardGlassEffect()
                        .contextMenu { SampleMenu() }
                    }
                }
            }
        }
    }
}

/// W2. Inside an outer container, but replace the button's glass with a
///    plain `.background(.ultraThinMaterial, in: shape)`. The button
///    then emits NO `.glassEffect`, so the outer container has nothing
///    to coordinate for it — and the contextMenu snapshot includes the
///    material background directly because it's just a regular modifier.
private struct W2_MaterialInsteadOfGlass: View {
    var body: some View {
        Variant(label: "W2. use .background(.ultraThinMaterial) instead of glass") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Text("Normal sibling (no interaction)")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .vehicleCardGlassEffect()

                    Button {} label: {
                        Text("Tap or hold — material")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .contextMenu { SampleMenu() }
                }
            }
        }
    }
}

/// W3. Inside an outer container, use `.compositingGroup()` to force the
///    button subtree (including its glass) to render as one unit before
///    `.contextMenu` snapshots it.
private struct W3_CompositingGroup: View {
    var body: some View {
        Variant(label: "W3. .compositingGroup() before .contextMenu") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Text("Normal sibling (no interaction)")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .vehicleCardGlassEffect()

                    Button {} label: {
                        Text("Tap or hold — compositingGroup")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .vehicleCardGlassEffect()
                    .compositingGroup()
                    .contextMenu { SampleMenu() }
                }
            }
        }
    }
}

/// W4. Same as W3 but with `.drawingGroup()` instead — more aggressive,
///    forces a Metal offscreen buffer of the subtree.
private struct W4_DrawingGroup: View {
    var body: some View {
        Variant(label: "W4. .drawingGroup() before .contextMenu") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Text("Normal sibling (no interaction)")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .vehicleCardGlassEffect()

                    Button {} label: {
                        Text("Tap or hold — drawingGroup")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .vehicleCardGlassEffect()
                    .drawingGroup()
                    .contextMenu { SampleMenu() }
                }
            }
        }
    }
}

/// Custom `ButtonStyle` that renders glass inside the style's own
/// `makeBody`. Because the glass surface is part of the Button's
/// intrinsic presentation (not a modifier chained after the Button),
/// `.contextMenu` snapshots the button-with-glass as a single unit.
///
/// Recommended by the StackOverflow + Substack guidance on iOS 26.1
/// `GlassEffectContainer` + menu morph regressions.
private struct GlassButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// W5. iOS 26.1-recommended pattern: glass rendered inside a custom
///    `ButtonStyle`, NOT via a modifier chained after the Button. When
///    the glass is part of the button's intrinsic presentation, the
///    contextMenu preview snapshots it as one unit and scales uniformly
///    even when wrapped in a `GlassEffectContainer`.
private struct W5_CustomButtonStyle: View {
    var body: some View {
        Variant(label: "W5. glass inside custom ButtonStyle") {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Text("Normal sibling (no interaction)")
                        .padding()
                        .frame(maxWidth: .infinity)
                        .vehicleCardGlassEffect()

                    Button {} label: {
                        Text("Tap or hold — custom style")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .contextMenu { SampleMenu() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Context menu variants") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            V1_Baseline()
            V2_PlainStyle()
            V3_Background()
            V4_GlassEffectDirect()
            V5_VehicleCardGlassEffect()
            V6_StylingInsideLabel()
            V7_OuterFrame()
            V8_HStackOfTwo()
            V9_ExplicitPreview()
            V10_NoPlainStyle()
            V11_InsideGlassEffectContainer()
            V12_ContainerWithSiblings()

            Divider()
            Text("Workarounds (all wrapped in outer GlassEffectContainer)")
                .font(.headline)

            W1_NestedContainer()
            W2_MaterialInsteadOfGlass()
            W3_CompositingGroup()
            W4_DrawingGroup()
            W5_CustomButtonStyle()
        }
        .padding()
    }
}
