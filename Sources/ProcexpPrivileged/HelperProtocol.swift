//
//  HelperProtocol.swift
//  ProcexpPrivileged — W2 (privileged XPC client + shared protocol)
//
//  The `@objc` XPC contract between the app (client) and the root helper
//  daemon (server), plus the shared identifiers used by both sides.
//
//  Wire format
//  -----------
//  Rather than teaching NSXPC about the whole `ProcexpModel` object graph via
//  `NSSecureCoding`, every structured payload is ferried as JSON `Data`
//  (encoded from the Codable DTOs in `PrivilegedDTO.swift`). Scalars that are
//  already property-list types (`String`, `Int32`) are passed directly. This
//  keeps the interface tiny and the security surface (allowed classes) small:
//  only `NSData`, `NSString`, `NSNumber` and `NSError` ever cross the boundary.
//

import Foundation

/// Identifiers shared by the client and the helper daemon.
public enum HelperConstants {
    public static let officialAppBundleID = "com.sysinternals.procexpmac"
    public static let developmentAppBundleID = "com.sysinternals.procexpmac.dev"

    public static let officialHelperBundleID = "com.sysinternals.procexpmac.helper"
    public static let developmentHelperBundleID = "com.sysinternals.procexpmac.dev.helper"

    private static var usesDevelopmentIdentity: Bool {
        switch Bundle.main.bundleIdentifier {
        case developmentAppBundleID, developmentHelperBundleID:
            return true
        case officialAppBundleID, officialHelperBundleID:
            return false
        default:
            return ProcessInfo.processInfo.environment["PROCEXP_HELPER_FLAVOR"] == "development"
        }
    }

    /// The mach service the daemon registers and the client connects to. Must
    /// match the `MachServices` key in the embedded launchd plist.
    public static var machServiceName: String {
        usesDevelopmentIdentity ? developmentHelperBundleID : officialHelperBundleID
    }

    /// The launchd property-list file name under
    /// `Contents/Library/LaunchDaemons/` used by `SMAppService.daemon(plistName:)`.
    public static var daemonPlistName: String {
        "\(machServiceName).plist"
    }

    /// Bundle identifier the helper's code signature is expected to carry once
    /// Developer-ID signed (W13). Used by the peer-validation requirement.
    public static var expectedHelperBundleID: String {
        machServiceName
    }
}

/// The privileged operations the root daemon exposes over XPC.
///
/// Every method uses a reply block (XPC one-way + reply). Structured results
/// arrive as JSON `Data` decoded into the DTOs; a non-nil `Error` signals
/// failure (already bridged to `NSError` across the boundary).
@objc public protocol ProcexpHelperProtocol {

    /// A full process snapshot encoded as `ProcessSnapshotDTO` JSON.
    func snapshot(withReply reply: @escaping (Data?, Error?) -> Void)

    /// Real per-thread detail (`[ThreadInfoDTO]` JSON) via `task_for_pid`.
    func threads(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void)

    /// Mapped modules (`[ModuleInfoDTO]` JSON).
    func modules(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void)

    /// Open file descriptors (`[FileDescriptorInfoDTO]` JSON).
    func fileDescriptors(pid: Int32, startTime: UInt64, withReply reply: @escaping (Data?, Error?) -> Void)

    /// The process command line (`nil` when unavailable). Root can read any user.
    func commandLine(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void)

    /// The process environment (`[String: String]` JSON).
    func environment(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void)

    /// The process current working directory (`nil` when unavailable).
    func currentDirectory(pid: Int32, withReply reply: @escaping (String?, Error?) -> Void)

    /// ASCII/Unicode strings scraped from the on-disk image (`[String]` JSON).
    func strings(pid: Int32, withReply reply: @escaping (Data?, Error?) -> Void)

    /// Send a POSIX signal to any process (kill / suspend / resume).
    func sendSignal(pid: Int32, signal: Int32, withReply reply: @escaping (Error?) -> Void)

    /// Set a process's `nice` value.
    func setNice(pid: Int32, nice: Int32, withReply reply: @escaping (Error?) -> Void)
}

/// Domain + codes for `NSError`s the helper returns across XPC. The client maps
/// these back onto `ProcexpModel.ProviderError`.
public enum HelperError {
    public static let domain = "com.sysinternals.procexpmac.helper.error"

    public enum Code: Int {
        case notPermitted = 1
        case processGone  = 2
        case unsupported  = 3
        case underlying   = 4
    }

    public static func make(_ code: Code, _ message: String) -> NSError {
        NSError(domain: domain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
