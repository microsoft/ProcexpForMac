//
//  Coloring.swift
//  ProcexpModel — W0 shared contracts
//
//  Row coloring rules mirroring Process Explorer's legend, expressed in a
//  UI-framework-neutral way (RGBA) so both AppKit and SwiftUI can consume them.
//

import Foundation

/// Framework-neutral color (0...1 components).
public struct RGBA: Sendable, Codable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) {
        self.init(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: a)
    }
}

/// A rule mapping a process flag to a background color (light/dark variants).
public struct ProcessColorRule: Sendable, Codable, Hashable, Identifiable {
    public var flag: ProcessFlags
    public var isEnabled: Bool
    public var backgroundLight: RGBA
    public var backgroundDark: RGBA

    public var id: UInt32 { flag.rawValue }

    public init(flag: ProcessFlags, isEnabled: Bool, backgroundLight: RGBA, backgroundDark: RGBA) {
        self.flag = flag
        self.isEnabled = isEnabled
        self.backgroundLight = backgroundLight
        self.backgroundDark = backgroundDark
    }

    /// The default legend, mirroring Process Explorer's colors. Order matters:
    /// earlier rules win when multiple flags are set (new/dead take priority).
    public static let defaults: [ProcessColorRule] = [
        .init(flag: .newProcess,  isEnabled: true, backgroundLight: RGBA(198, 246, 198), backgroundDark: RGBA(40, 90, 40)),
        .init(flag: .deadProcess, isEnabled: true, backgroundLight: RGBA(246, 198, 198), backgroundDark: RGBA(110, 40, 40)),
        .init(flag: .suspended,   isEnabled: true, backgroundLight: RGBA(200, 200, 200), backgroundDark: RGBA(70, 70, 70)),
        .init(flag: .service,     isEnabled: true, backgroundLight: RGBA(255, 208, 208), backgroundDark: RGBA(90, 55, 55)),
        .init(flag: .ownProcess,  isEnabled: true, backgroundLight: RGBA(208, 208, 255), backgroundDark: RGBA(55, 55, 90)),
        .init(flag: .sandboxed,   isEnabled: true, backgroundLight: RGBA(208, 246, 246), backgroundDark: RGBA(40, 80, 80)),
        .init(flag: .packed,      isEnabled: true, backgroundLight: RGBA(230, 208, 246), backgroundDark: RGBA(70, 50, 90)),
    ]

    /// Resolve the background color for a process given the active rules.
    /// Returns nil when no enabled rule matches (default row background).
    public static func background(
        for flags: ProcessFlags,
        rules: [ProcessColorRule],
        darkMode: Bool
    ) -> RGBA? {
        for rule in rules where rule.isEnabled && flags.contains(rule.flag) {
            return darkMode ? rule.backgroundDark : rule.backgroundLight
        }
        return nil
    }
}
