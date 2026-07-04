//
//  BundleMetadataCache.swift
//  ProcexpSampling — static per-executable bundle metadata (fix #4)
//
//  Version / description / company for a process come from the enclosing app
//  bundle's `Info.plist`. That data is static per executable path, so we read
//  it once and cache it for the lifetime of the process. The cache is queried
//  synchronously from the sampling pass (which may run off the main actor), so
//  it guards its storage with a lock and is `@unchecked Sendable`.
//

import Foundation

final class BundleMetadataCache: @unchecked Sendable {
    static let shared = BundleMetadataCache()

    struct Metadata: Sendable {
        var version: String?
        var displayDescription: String?
        var companyName: String?
        var bundleIdentifier: String?
        var bundlePath: String?
    }

    private let lock = NSLock()
    private var cache: [String: Metadata] = [:]

    /// Bundle metadata for the given executable path. First lookup reads the
    /// enclosing bundle's `Info.plist` (or returns empty metadata for a
    /// non-bundled CLI tool); every later lookup is a cheap cache hit. Negative
    /// results are cached too, so unreadable/plain executables are only probed
    /// once.
    func metadata(forExecutablePath path: String) -> Metadata {
        lock.lock()
        if let hit = cache[path] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = Self.resolve(executablePath: path)

        lock.lock()
        cache[path] = resolved
        lock.unlock()
        return resolved
    }

    // MARK: - Resolution

    private static func resolve(executablePath path: String) -> Metadata {
                guard let bundleURL = bundleURL(forExecutablePath: path) else {
                        // Non-bundled tool or unreadable Info.plist -> no metadata.
                        return Metadata()
                }
                let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
                guard
              let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let dict = plist as? [String: Any]
        else {
            // Non-bundled tool or unreadable Info.plist → no metadata.
            return Metadata()
        }

        let version = nonEmpty(dict["CFBundleShortVersionString"] as? String)
            ?? nonEmpty(dict["CFBundleVersion"] as? String)
        let description = nonEmpty(dict["CFBundleDisplayName"] as? String)
            ?? nonEmpty(dict["CFBundleName"] as? String)
        let bundleID = nonEmpty(dict["CFBundleIdentifier"] as? String)

        return Metadata(
            version: version,
            displayDescription: description,
            companyName: company(fromBundleID: bundleID),
            bundleIdentifier: bundleID,
            bundlePath: bundleURL.path)
    }

    /// Locate the `Info.plist` for the enclosing bundle of a
    /// `.../Xxx.app/Contents/MacOS/exe` (or `.xpc` / `.appex`) executable path.
    private static func bundleURL(forExecutablePath path: String) -> URL? {
        let markers = [".app/Contents/MacOS/", ".xpc/Contents/MacOS/", ".appex/Contents/MacOS/"]
        for marker in markers {
            guard let range = path.range(of: marker) else { continue }
            // Bundle root is everything up to and including the ".app" (etc.).
            let suffix = String(marker.prefix { $0 != "/" })   // e.g. ".app"
            let bundleRoot = String(path[..<range.lowerBound]) + suffix
            let infoPath = bundleRoot + "/Contents/Info.plist"
            if FileManager.default.fileExists(atPath: infoPath) {
                return URL(fileURLWithPath: bundleRoot)
            }
        }
        return nil
    }

    /// Derive a human-readable company from the reverse-DNS bundle id's org
    /// segment (`com.apple.finder` → "Apple"). Returns `nil` when the id has no
    /// usable org segment.
    private static func company(fromBundleID id: String?) -> String? {
        guard let id else { return nil }
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let org = String(parts[1])
        guard !org.isEmpty else { return nil }
        return org.prefix(1).uppercased() + org.dropFirst()
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
