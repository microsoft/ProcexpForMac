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

    /// Resolves as much version/description/company information as possible from
    /// several sources, in order of specificity:
    ///   1. The enclosing `.app`/`.xpc`/`.appex` bundle's `Info.plist` (the
    ///      executable lives in `Contents/MacOS/`).
    ///   2. An `Info.plist` embedded directly in the Mach-O (`__TEXT,__info_plist`)
    ///      — how many bare system daemons / CLI tools carry version info.
    ///   3. The nearest enclosing bundle of any kind (`.bundle`, `.framework`,
    ///      …), e.g. `powerd.bundle` or a daemon shipped inside a framework.
    private static func resolve(executablePath path: String) -> Metadata {
        if let root = directBundleRoot(forExecutablePath: path),
           let dict = infoDictionary(atBundleRoot: root) {
            let m = metadata(from: dict, bundlePath: root)
            if hasContent(m) { return m }
        }
        if let dict = embeddedInfoDictionary(forExecutablePath: path) {
            let m = metadata(from: dict, bundlePath: nil)
            if hasContent(m) { return m }
        }
        if let (dict, root) = enclosingBundleInfoDictionary(forExecutablePath: path) {
            let m = metadata(from: dict, bundlePath: root)
            if hasContent(m) { return m }
        }
        return Metadata()
    }

    private static func hasContent(_ m: Metadata) -> Bool {
        m.version != nil || m.displayDescription != nil
            || m.companyName != nil || m.bundleIdentifier != nil
    }

    /// Extract the fields we surface from an `Info.plist` dictionary.
    private static func metadata(from dict: [String: Any], bundlePath: String?) -> Metadata {
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
            bundlePath: bundlePath)
    }

    private static func infoDictionary(atBundleRoot root: String) -> [String: Any]? {
        for rel in ["Contents/Info.plist", "Resources/Info.plist",
                    "Versions/Current/Resources/Info.plist", "Info.plist"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    /// Root of the `.app`/`.xpc`/`.appex` bundle whose executable is at
    /// `.../Xxx.app/Contents/MacOS/exe`, or `nil` for a bare executable.
    private static func directBundleRoot(forExecutablePath path: String) -> String? {
        let markers = [".app/Contents/MacOS/", ".xpc/Contents/MacOS/", ".appex/Contents/MacOS/"]
        for marker in markers {
            guard let range = path.range(of: marker) else { continue }
            let suffix = String(marker.prefix { $0 != "/" })   // e.g. ".app"
            let root = String(path[..<range.lowerBound]) + suffix
            if FileManager.default.fileExists(atPath: root + "/Contents/Info.plist") {
                return root
            }
        }
        return nil
    }

    /// Walks up from the executable to the nearest enclosing bundle directory of
    /// any kind and returns its `Info.plist` dictionary + root path.
    private static func enclosingBundleInfoDictionary(forExecutablePath path: String) -> ([String: Any], String)? {
        let exts = [".app", ".xpc", ".appex", ".bundle", ".framework", ".kext", ".plugin"]
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<16 {
            let name = url.lastPathComponent
            if exts.contains(where: { name.hasSuffix($0) }),
               let dict = infoDictionary(atBundleRoot: url.path) {
                return (dict, url.path)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    // MARK: - Embedded Info.plist (Mach-O __TEXT,__info_plist)

    /// Reads an `Info.plist` embedded in the Mach-O's `__TEXT,__info_plist`
    /// section, if present. Handles thin and fat 64-bit binaries; 32-bit and
    /// malformed images yield `nil`.
    private static func embeddedInfoDictionary(forExecutablePath path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= 8 else { return nil }

        let magic = u32(data, 0, false) ?? 0
        var sliceOffset = 0
        switch magic {
        case 0xfeed_facf, 0xcffa_edfe:                       // MH_MAGIC_64 / MH_CIGAM_64
            break
        case 0xfeed_face, 0xcefa_edfe:                       // 32-bit — not supported
            return nil
        case 0xcafe_babe, 0xbeba_feca, 0xcafe_babf, 0xbfba_feca:   // fat
            guard let s = fatSliceOffset(data, magic: magic) else { return nil }
            sliceOffset = s
        default:
            return nil
        }

        let sliceMagic = u32(data, sliceOffset, false) ?? 0
        let big: Bool
        switch sliceMagic {
        case 0xfeed_facf: big = false
        case 0xcffa_edfe: big = true
        default: return nil
        }
        return parseThin64(data, sliceOffset: sliceOffset, big: big)
    }

    private static func fatSliceOffset(_ data: Data, magic: UInt32) -> Int? {
        let is64 = (magic == 0xcafe_babf || magic == 0xbfba_feca)   // FAT_MAGIC_64 variants
        guard let nfat = u32(data, 4, true) else { return nil }     // fat header is big-endian
        let archSize = is64 ? 32 : 20
        var best: Int?
        var bestRank = Int.max
        var p = 8
        for _ in 0..<Int(nfat) {
            guard let cputype = u32(data, p, true) else { break }
            let offset = is64 ? (u64(data, p + 8, true) ?? 0) : UInt64(u32(data, p + 8, true) ?? 0)
            let rank: Int
            switch Int32(bitPattern: cputype) {
            case 0x0100_000c: rank = 0   // CPU_TYPE_ARM64
            case 0x0100_0007: rank = 1   // CPU_TYPE_X86_64
            default:          rank = 2
            }
            if rank < bestRank { bestRank = rank; best = Int(offset) }
            p += archSize
        }
        return best
    }

    private static func parseThin64(_ data: Data, sliceOffset: Int, big: Bool) -> [String: Any]? {
        guard let ncmds = u32(data, sliceOffset + 16, big) else { return nil }
        var cmdOffset = sliceOffset + 32                 // sizeof(mach_header_64)
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32(data, cmdOffset, big),
                  let cmdSize = u32(data, cmdOffset + 4, big), cmdSize >= 8 else { return nil }
            if cmd == 0x19 {                             // LC_SEGMENT_64
                if cstr(data, cmdOffset + 8, 16) == "__TEXT",
                   let nsects = u32(data, cmdOffset + 64, big) {
                    var secOffset = cmdOffset + 72       // sizeof(segment_command_64)
                    for _ in 0..<Int(nsects) {
                        if cstr(data, secOffset, 16) == "__info_plist",
                           let size = u64(data, secOffset + 40, big),
                           let off = u32(data, secOffset + 48, big) {
                            let start = sliceOffset + Int(off)
                            let len = Int(size)
                            guard len > 0, start >= 0, start + len <= data.count else { return nil }
                            let plistData = data.subdata(in: start..<start + len)
                            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
                               let dict = plist as? [String: Any] {
                                return dict
                            }
                            return nil
                        }
                        secOffset += 80                  // sizeof(section_64)
                    }
                }
            }
            cmdOffset += Int(cmdSize)
        }
        return nil
    }

    private static func u32(_ d: Data, _ o: Int, _ big: Bool) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        let b = [UInt8](d[o..<o + 4])
        let le = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return big ? le.byteSwapped : le
    }

    private static func u64(_ d: Data, _ o: Int, _ big: Bool) -> UInt64? {
        guard o >= 0, o + 8 <= d.count else { return nil }
        let b = [UInt8](d[o..<o + 8])
        var le: UInt64 = 0
        for i in 0..<8 { le |= UInt64(b[i]) << (8 * i) }
        return big ? le.byteSwapped : le
    }

    private static func cstr(_ d: Data, _ o: Int, _ maxLen: Int) -> String {
        guard o >= 0, o + maxLen <= d.count else { return "" }
        let bytes = [UInt8](d[o..<o + maxLen]).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
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
