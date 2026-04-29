//
//  Pasteboard.swift
//  BetterBlue
//
//  Tiny cross-platform shim over `UIPasteboard` (iOS) and `NSPasteboard`
//  (macOS) so view code can copy strings without scattering `#if`
//  branches at every call site.
//

import Foundation

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(iOS)
            UIPasteboard.general.string = string
        #elseif os(macOS)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(string, forType: .string)
        #endif
    }
}
