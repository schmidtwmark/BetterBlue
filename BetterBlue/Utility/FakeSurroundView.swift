//
//  FakeSurroundView.swift
//  BetterBlue
//
//  Synthetic surround-view captures for fake vehicles.
//
//  Real surround view can only be exercised against a car that has the
//  cameras, on a region that exposes them, and it costs a PIN-authorized
//  remote call plus a multi-minute wait each time. That is a poor loop to
//  develop the UI against, so fake vehicles produce captures that look and
//  behave like the real thing:
//
//    * the imagery is a single wide composite strip, the shape Hyundai
//      Canada returns, so it flows through the SAME decode/slice code the
//      live client uses (`SurroundViewDecoder`) rather than a shortcut;
//    * the capture is asynchronous — a request doesn't land until a short
//      delay has passed, so the view's "waiting" state and its polling
//      loop are genuinely exercised;
//    * captures accumulate into a bounded history, newest first, matching
//      what the Kia and Hyundai backends retain.
//

import BetterBlueKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Store

/// In-memory surround-view state for fake vehicles.
///
/// Deliberately not persisted: the imagery is regenerated cheaply, and
/// keeping megabytes of synthetic JPEG out of the shared SwiftData store
/// avoids inflating the container that the widgets and watch app also
/// open.
@MainActor
final class FakeSurroundViewStore {
    static let shared = FakeSurroundViewStore()

    /// How long a fake vehicle "takes" to wake its cameras and upload.
    /// Longer than one poll interval on purpose, so requesting a capture
    /// in the simulator actually shows the waiting state before the
    /// images arrive.
    static let captureDelay: TimeInterval = 35
    /// Matches the ten captures Kia's backend retains.
    private static let historyLimit = 10

    private var captures: [String: [SurroundViewCapture]] = [:]
    private var pendingSince: [String: Date] = [:]
    /// VINs whose pending request is set never to complete, so the view's
    /// six-minute give-up path is reachable on demand.
    private var stalledVins: Set<String> = []

    private init() {}

    /// Records a capture request. The imagery materializes only once
    /// `captureDelay` has elapsed and something asks for it.
    func requestCapture(vin: String, neverCompletes: Bool = false) {
        pendingSince[vin] = Date()
        if neverCompletes {
            stalledVins.insert(vin)
        } else {
            stalledVins.remove(vin)
        }
        BBLogger.info(
            .fakeAPI,
            "FakeSurroundView: capture requested for '\(vin)'\(neverCompletes ? " (will never complete)" : "")"
        )
    }

    /// Drops a set of back-dated captures straight into the history, so
    /// the "Earlier Captures" picker can be exercised without waiting out
    /// a capture per entry.
    ///
    /// Timestamps are whole seconds and strictly increasing because a
    /// capture's identity is `vin` plus `Int(capturedAt.timeIntervalSince1970)`
    /// — sub-second spacing would collide two entries onto one id.
    func seedHistory(vin: String, count: Int = 3) {
        let now: TimeInterval = Date().timeIntervalSince1970.rounded(.down)
        var seeded: [SurroundViewCapture] = []

        for index in 0 ..< count {
            let age: TimeInterval = TimeInterval(index + 1) * 900
            // Vary the metadata so the detail rows below the image —
            // including the folded-mirror warning, which fires on
            // `false` and not on nil — actually render somewhere.
            let capture = FakeSurroundViewImage.makeCapture(
                vin: vin,
                capturedAt: Date(timeIntervalSince1970: now - age),
                sideMirrorOpen: index % 2 != 0,
                trunkOpen: index == 1
            )
            if let capture {
                seeded.append(capture)
            }
        }

        captures[vin] = (seeded + (captures[vin] ?? []))
            .sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
            .prefix(Self.historyLimit)
            .map { $0 }
        BBLogger.info(.fakeAPI, "FakeSurroundView: seeded \(seeded.count) capture(s) for '\(vin)'")
    }

    /// The captures currently available, newest first — promoting a
    /// pending request first if it has had time to complete.
    func captures(vin: String) -> [SurroundViewCapture] {
        settlePendingCapture(vin: vin)
        return captures[vin] ?? []
    }

    /// Drops a vehicle's history. Used when a fake vehicle is reset.
    func reset(vin: String) {
        captures[vin] = nil
        pendingSince[vin] = nil
    }

    private func settlePendingCapture(vin: String) {
        guard let requestedAt = pendingSince[vin],
              !stalledVins.contains(vin),
              Date().timeIntervalSince(requestedAt) >= Self.captureDelay else {
            return
        }

        pendingSince[vin] = nil

        guard let capture = FakeSurroundViewImage.makeCapture(vin: vin, capturedAt: Date()) else {
            BBLogger.error(.fakeAPI, "FakeSurroundView: failed to synthesize imagery for '\(vin)'")
            return
        }

        captures[vin] = ([capture] + (captures[vin] ?? [])).prefix(Self.historyLimit).map { $0 }
        BBLogger.info(
            .fakeAPI,
            "FakeSurroundView: capture ready for '\(vin)' (\(capture.byteCount) bytes, \(capture.tiles.count) tiles)"
        )
    }
}

// MARK: - Image synthesis

enum FakeSurroundViewImage {
    /// The layout Hyundai Canada reports for a real capture: four 960px
    /// fisheye views followed by a 632px bird's-eye view, all 720 tall.
    /// Reusing the real numbers means the fake capture exercises the
    /// production tiling maths instead of a special case.
    static let imageSize = [4472, 720, 960, 720, 632, 720]

    private typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    private static let panels: [(label: String, color: RGB)] = [
        ("FRONT", (0.16, 0.33, 0.55)),
        ("REAR", (0.42, 0.20, 0.36)),
        ("LEFT", (0.18, 0.42, 0.36)),
        ("RIGHT", (0.50, 0.34, 0.14)),
        ("TOP", (0.22, 0.24, 0.30))
    ]

    /// Builds a capture whose imagery goes through the same JPEG-splitting
    /// and tile-slicing the live Hyundai Canada client uses.
    static func makeCapture(
        vin: String,
        capturedAt: Date,
        sideMirrorOpen: Bool = true,
        trunkOpen: Bool = false
    ) -> SurroundViewCapture? {
        guard let strip = makeCompositeStrip(vin: vin, capturedAt: capturedAt) else { return nil }

        // Round-trip through the real decoder rather than handing the
        // view a hand-built frame list: if frame extraction regresses,
        // the fake vehicle shows it too.
        let frames = SurroundViewDecoder.extractJPEGFrames(from: strip)
        guard !frames.isEmpty else { return nil }

        // The crop path silently falls back to showing the whole strip
        // when a rect doesn't fit its frame, so a wrong-sized synthetic
        // image would look plausible while proving nothing about tiling.
        assert(
            decodedSize(of: frames[0]) == CGSize(width: imageSize[0], height: imageSize[1]),
            "Synthetic strip is \(String(describing: decodedSize(of: frames[0]))), "
                + "expected \(imageSize[0])x\(imageSize[1]) — tile crops would silently fall back"
        )

        return SurroundViewCapture(
            vin: vin,
            capturedAt: capturedAt,
            location: VehicleStatus.Location(latitude: 37.334_886, longitude: -122.008_988),
            heading: 93,
            doorOpen: VehicleStatus.DoorStatus(
                frontLeft: false,
                frontRight: true,
                backLeft: false,
                backRight: false
            ),
            trunkOpen: trunkOpen,
            sideMirrorOpen: sideMirrorOpen,
            frames: frames,
            tiles: SurroundViewDecoder.tiles(imageSize: imageSize, frameCount: frames.count)
        )
    }

    /// Pixel dimensions of an encoded JPEG, read from its header without
    /// decoding the pixels.
    static func decodedSize(of jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Renders the wide composite strip: one labelled panel per camera,
    /// laid out left to right exactly as the payload describes.
    ///
    /// Drawn with CoreGraphics and CoreText rather than
    /// `UIGraphicsImageRenderer`, which is unavailable on watchOS — this
    /// file is shared with the watch and widget targets because they
    /// compile the fake vehicle provider.
    private static func makeCompositeStrip(vin: String, capturedAt: Date) -> Data? {
        let totalWidth = imageSize[0]
        let totalHeight = imageSize[1]
        let cameraWidth = imageSize[2]
        let topDownWidth = imageSize[4]

        guard let context = CGContext(
            data: nil,
            width: totalWidth,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            // Opaque: the strip is JPEG-encoded, which has no alpha.
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        var originX = 0
        for (index, panel) in panels.enumerated() {
            let width = index == panels.count - 1 ? topDownWidth : cameraWidth
            let rect = CGRect(x: originX, y: 0, width: width, height: totalHeight)

            context.setFillColor(red: panel.color.red, green: panel.color.green, blue: panel.color.blue, alpha: 1)
            context.fill(rect)

            // A hairline seam makes a mis-sliced tile obvious at a glance:
            // a crop that is off by a panel shows the neighbouring border
            // instead of a clean edge.
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.35)
            context.setLineWidth(4)
            context.stroke(rect.insetBy(dx: 2, dy: 2))

            draw(panel: panel.label, vin: vin, capturedAt: capturedAt, in: rect, context: context)
            originX += width
        }

        guard let image = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    private static func draw(
        panel label: String,
        vin: String,
        capturedAt: Date,
        in rect: CGRect,
        context: CGContext
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let title = line(label, size: 120, weight: "Helvetica-Bold", alpha: 1)
        let subtitle = line(
            "\(vin.suffix(6)) · \(formatter.string(from: capturedAt))",
            size: 44,
            weight: "Menlo-Regular",
            alpha: 0.75
        )

        // CoreGraphics puts the origin at the bottom-left, so the
        // subtitle sits *below* the title at a lower y.
        drawCentered(title, in: rect, offsetY: 24, context: context)
        drawCentered(subtitle, in: rect, offsetY: -76, context: context)
    }

    private static func line(_ text: String, size: CGFloat, weight: String, alpha: CGFloat) -> CTLine {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        let color = CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func drawCentered(_ line: CTLine, in rect: CGRect, offsetY: CGFloat, context: CGContext) {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY + offsetY)
        CTLineDraw(line, context)
    }
}
