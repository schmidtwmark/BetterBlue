//
//  ColorSelectionView.swift
//  BetterBlue
//
//  Reusable color-picker screen used by the per-vehicle Customization
//  section. Renders a grid of *real-control* previews from
//  `CustomColor.palette` with a checkmark on the current selection.
//  Pushed via NavigationLink from the customization rows.
//

import SwiftUI

/// Tells the picker how to render its swatches so each preview is a
/// miniature of the actual on-screen control the color drives, instead
/// of a generic dot.
enum ColorPreviewStyle: Hashable {
    /// Map pin: filled circle, white stroke, white car icon — matches
    /// `VehicleMapMarker` in SimpleMapView.
    case mapMarker
    /// Quick-action button: rounded glass chip with a tinted SF Symbol
    /// — matches the right-side button in `VehicleControlButton`.
    case quickAction(symbol: String)
}

struct ColorSelectionView: View {
    let title: String
    /// Two-way binding into the BBVehicle property holding the chosen
    /// palette name. `nil` means "use the default" — the row passes
    /// `defaultName` so we can still highlight the right swatch.
    @Binding var selectedName: String?
    /// Palette key to highlight when `selectedName == nil`.
    let defaultName: String
    /// Picks which on-screen control the preview imitates.
    let previewStyle: ColorPreviewStyle
    /// Fired after a successful selection so callers can `try?
    /// modelContext.save()` and refresh widget timelines if needed.
    var onChange: (() -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 12)
    ]

    private var resolvedSelection: String {
        selectedName ?? defaultName
    }

    private var isOnDefault: Bool {
        selectedName == nil || selectedName == defaultName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(CustomColor.palette) { option in
                        Button {
                            // Storing nil for the default keeps the column
                            // empty in SwiftData when the user picks the
                            // default — easier diffs, easier migrations.
                            selectedName = (option.name == defaultName) ? nil : option.name
                            onChange?()
                        } label: {
                            swatch(for: option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Toolbar reset keeps the grid uncluttered. Disabled when
            // already on the default so the affordance still shows what
            // the screen *can* do, but no-ops on tap.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") {
                    selectedName = nil
                    onChange?()
                }
                .disabled(isOnDefault)
            }
        }
    }

    @ViewBuilder
    private func swatch(for option: CustomColor.Option) -> some View {
        let isSelected = option.name == resolvedSelection
        let isDefault = option.name == defaultName

        // Name on top, preview below. The "(Default)" tag rides inline
        // with the name so the row stays a single line — that keeps the
        // preview directly under its label, making it obvious which
        // color goes with which swatch.
        VStack(spacing: 6) {
            Text(isDefault ? "\(option.displayName) (Default)" : option.displayName)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(1)

            ZStack(alignment: .topTrailing) {
                ColorPreviewView(color: option.color, style: previewStyle, size: 56)
                    .overlay {
                        if isSelected {
                            // Selection outline matches the
                            // BackgroundSelectionView treatment (blue ring)
                            // and adopts the preview's shape so it fits
                            // snugly against either the disc or the chip.
                            Group {
                                switch previewStyle {
                                case .mapMarker:
                                    Circle().stroke(Color.blue, lineWidth: 2)
                                case .quickAction:
                                    let radius = 56 * (12.0 / 52.0)
                                    RoundedRectangle(cornerRadius: radius)
                                        .stroke(Color.blue, lineWidth: 2)
                                }
                            }
                        }
                    }

                if isSelected {
                    // ZStack-on-top so the badge is never clipped by the
                    // preview's container shape and always reads above
                    // the selection ring.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white, Color.blue)
                        .background(Circle().fill(Color(.systemBackground)).padding(2))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Miniature of a real on-screen control rendered in a given color.
/// Reused by both the picker grid and the row preview so the two stay
/// visually consistent.
struct ColorPreviewView: View {
    let color: Color
    let style: ColorPreviewStyle
    /// Edge length for the preview. Picker uses ~56pt; rows use ~28pt.
    var size: CGFloat = 56

    var body: some View {
        switch style {
        case .mapMarker:
            // Mirrors VehicleMapMarker: solid color disc, white ring,
            // white car icon. Stroke + icon scale with the requested size.
            let strokeWidth = max(1, size / 18)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(
                    Circle().stroke(Color.white, lineWidth: strokeWidth)
                )
                .overlay(
                    Image(systemName: "car.fill")
                        .foregroundColor(.white)
                        .font(.system(size: size * 0.42, weight: .semibold))
                )
        case .quickAction(let symbol):
            // Mirrors `quickActionButtonLabel`: tinted SF Symbol on the
            // shared `vehicleCardGlassEffect` chip. The real button is
            // 52pt with a 12pt corner radius, so we scale the radius
            // proportionally — otherwise small previews look like
            // circles instead of rounded squares.
            let radius = size * (12.0 / 52.0)
            Image(systemName: symbol)
                .foregroundColor(color)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .vehicleCardGlassEffect(radius: radius)
        }
    }
}
