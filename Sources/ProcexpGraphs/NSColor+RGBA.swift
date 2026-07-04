//
//  NSColor+RGBA.swift
//  ProcexpGraphs — W4
//
//  Bridge ProcexpModel's framework-neutral RGBA into AppKit NSColor.
//

import AppKit
import ProcexpModel

extension NSColor {
    /// Create an sRGB NSColor from a framework-neutral RGBA value.
    convenience init(_ rgba: RGBA) {
        self.init(
            srgbRed: CGFloat(rgba.r),
            green: CGFloat(rgba.g),
            blue: CGFloat(rgba.b),
            alpha: CGFloat(rgba.a)
        )
    }
}
