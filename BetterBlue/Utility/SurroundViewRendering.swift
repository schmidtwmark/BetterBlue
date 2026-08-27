//
//  SurroundViewRendering.swift
//  BetterBlue
//
//  Turning a surround-view capture into displayable or shareable images.
//
//  A capture is usually ONE wide composite JPEG holding every camera
//  side by side, plus a table of crop rects saying where each view sits
//  (see `SurroundViewDecoder` in BetterBlueKit). Everything that wants a
//  single camera — the monitor screen, the Shortcuts action — has to do
//  the same decode-and-crop, so it lives here once.
//
//  Written against CoreGraphics/ImageIO rather than UIKit's `UIImage`
//  conveniences because this file is shared with the watch and widget
//  targets, and `UIImage.jpegData(compressionQuality:)` is unavailable
//  on watchOS.
//

import BetterBlueKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SurroundViewRendering {
    /// The tile for a camera, or the capture's first tile when that
    /// camera isn't part of this capture.
    static func tile(
        in capture: SurroundViewCapture,
        position: SurroundViewCameraPosition?
    ) -> SurroundViewTile? {
        if let position, let match = capture.tiles.first(where: { $0.position == position }) {
            return match
        }
        return capture.tiles.first
    }

    /// Decodes and crops one camera view out of its frame.
    ///
    /// Pass `decodedFrames` when rendering several tiles of the same
    /// capture: a composite is a single 4472px-wide JPEG shared by every
    /// tile, so decoding it once and reusing it avoids repeating the
    /// expensive half per camera.
    static func image(
        in capture: SurroundViewCapture,
        position: SurroundViewCameraPosition?,
        decodedFrames: inout [Int: CGImage]
    ) -> CGImage? {
        guard let tile = tile(in: capture, position: position),
              capture.frames.indices.contains(tile.frameIndex) else {
            return nil
        }

        let frame: CGImage
        if let cached = decodedFrames[tile.frameIndex] {
            frame = cached
        } else if let decoded = decodeJPEG(capture.frames[tile.frameIndex]) {
            decodedFrames[tile.frameIndex] = decoded
            frame = decoded
        } else {
            return nil
        }

        guard let crop = tile.crop else { return frame }

        let rect = CGRect(x: crop.originX, y: crop.originY, width: crop.width, height: crop.height)
            .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))

        // Geometry that doesn't fit the image is a payload shape we don't
        // understand — show the whole strip rather than nothing.
        guard !rect.isEmpty, let cropped = frame.cropping(to: rect) else { return frame }
        return cropped
    }

    /// Convenience for a single tile, when there's no batch to share a
    /// decoded frame with.
    static func image(in capture: SurroundViewCapture, position: SurroundViewCameraPosition?) -> CGImage? {
        var frames: [Int: CGImage] = [:]
        return image(in: capture, position: position, decodedFrames: &frames)
    }

    /// JPEG bytes for one camera view, ready to hand to Shortcuts or the
    /// share sheet.
    static func jpegData(
        in capture: SurroundViewCapture,
        position: SurroundViewCameraPosition?,
        compressionQuality: CGFloat = 0.9
    ) -> Data? {
        guard let image = image(in: capture, position: position) else { return nil }
        return encodeJPEG(image, compressionQuality: compressionQuality)
    }

    // MARK: - Codec

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encodeJPEG(_ image: CGImage, compressionQuality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
