//
//  Color+RGBA.swift
//  W11 — Bridge between the framework-neutral `RGBA` used by the model/legend
//  and SwiftUI's `Color`, so `ColorPicker`s can edit `ProcessColorRule`s.
//
//  Conversions go through the sRGB color space in both directions so a value
//  survives a Color → RGBA → Color round-trip without drifting.
//

import SwiftUI
import AppKit
import ProcexpModel

extension Color {
    /// Build a SwiftUI color from a legend `RGBA` (components already sRGB 0…1).
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    /// Extract sRGB components as an `RGBA` for storage in the model/UserDefaults.
    var rgba: RGBA {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RGBA(
            r: Double(ns.redComponent),
            g: Double(ns.greenComponent),
            b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent)
        )
    }
}

extension Binding where Value == RGBA {
    /// Adapt an `RGBA` binding for a SwiftUI `ColorPicker` (which wants `Color`).
    var asColor: Binding<Color> {
        Binding<Color>(
            get: { Color(rgba: wrappedValue) },
            set: { wrappedValue = $0.rgba }
        )
    }
}
