//
//  ModuleDetailWindow.swift
//  R3 — DLL / mapped-image detail window.
//
//  Opened by double-clicking a row in the lower pane's DLLs list. Shows the
//  image's name/path, resolved bundle metadata (description/company/version),
//  its mapped base address and size, and a live code-signature section with
//  "Reveal in Finder" and "VirusTotal" actions. Presented as a
//  `WindowGroup(for: ModuleDetailID.self)` so several may be open at once.
//

import SwiftUI
import AppKit
import ProcexpModel

/// Scene identifier for the DLL/image detail `WindowGroup`.
enum ModuleDetailWindow {
    static let id = "module-detail"
}

/// Codable & Hashable identifier carrying everything needed to render an image
/// detail window without re-scanning the owning process. The code signature is
/// still fetched live (async) from the path.
struct ModuleDetailID: Codable, Hashable {
    var pid: Int32
    var startTime: UInt64
    var path: String
    var name: String
    var loadAddress: UInt64
    var size: UInt64
    var isMappedFile: Bool
    var processName: String
}

/// Resolves best-effort human-readable metadata for a mapped image by reading
/// the `Info.plist` of the nearest enclosing bundle (.app/.framework/.bundle/
/// .xpc). Results are cached (thread-safe `NSCache`) since the resolver is
/// called off the main actor while building large module lists.
enum ModuleMetadata {
    struct Meta: Sendable, Hashable {
        var description: String
        var company: String
        var version: String
    }

    private static let cache = NSCache<NSString, Box>()

    private final class Box {
        let meta: Meta
        init(_ meta: Meta) { self.meta = meta }
    }

    static func resolve(path: String) -> Meta {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached.meta }
        let meta = compute(path: path)
        cache.setObject(Box(meta), forKey: key)
        return meta
    }

    private static let bundleExtensions: Set<String> =
        ["app", "framework", "bundle", "xpc", "appex", "plugin", "kext"]

    private static func compute(path: String) -> Meta {
        guard let info = infoDictionary(forPath: path) else {
            // No enclosing bundle (e.g. a bare /usr/lib dylib). Still try to
            // attribute a company for well-known system paths.
            return Meta(description: "", company: systemCompany(forPath: path), version: "")
        }

        let description =
            (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ""

        let version =
            (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""

        let company = companyName(info: info, path: path)

        return Meta(description: description, company: company, version: version)
    }

    /// Reads the `Info.plist` of `path` itself (if it is a bundle) or of the
    /// nearest enclosing bundle directory.
    private static func infoDictionary(forPath path: String) -> [String: Any]? {
        if let bundle = Bundle(path: path), let info = bundle.infoDictionary,
           info["CFBundleIdentifier"] != nil || info["CFBundleName"] != nil {
            return info
        }
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            let ext = url.pathExtension.lowercased()
            if bundleExtensions.contains(ext),
               let bundle = Bundle(url: url),
               let info = bundle.infoDictionary {
                return info
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Derives a company name from the bundle identifier, falling back to a
    /// system-path heuristic.
    private static func companyName(info: [String: Any], path: String) -> String {
        if let identifier = info["CFBundleIdentifier"] as? String {
            let parts = identifier.split(separator: ".")
            if parts.count >= 2 {
                let tlds: Set<String> = ["com", "org", "io", "net", "co", "dev"]
                if tlds.contains(String(parts[0]).lowercased()) {
                    let org = String(parts[1])
                    if org.lowercased() == "apple" { return "Apple Inc." }
                    return org.prefix(1).uppercased() + org.dropFirst()
                }
            }
        }
        return systemCompany(forPath: path)
    }

    private static func systemCompany(forPath path: String) -> String {
        let systemPrefixes = ["/System/", "/usr/lib/", "/usr/libexec/", "/bin/", "/sbin/"]
        return systemPrefixes.contains(where: path.hasPrefix) ? "Apple Inc." : ""
    }
}

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: ModuleDetailID

    @State private var meta = ModuleMetadata.Meta(description: "", company: "", version: "")
    @State private var signature: SignatureInfo?
    @State private var loadingSignature = true
    @State private var vtStatus: String?
    @State private var vtPermalink: String?
    @State private var vtBusy = false

    private var fileURL: URL { URL(fileURLWithPath: id.path) }
    private var fileExists: Bool { FileManager.default.fileExists(atPath: id.path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                imageSection
                Divider()
                signatureSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 440)
        .navigationTitle("\(id.name) Properties")
        .task {
            meta = ModuleMetadata.resolve(path: id.path)
            await loadSignature()
        }
        .onExitCommand { dismiss() }
        .background(EscapeKeyMonitor { dismiss() })
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: id.path))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.name)
                    .font(.title3).bold()
                    .textSelection(.enabled)
                ScrollingValue(text: id.path, font: .callout)
                    .foregroundStyle(.secondary)
                Text("Loaded by \(id.processName) (PID \(id.pid))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Image details

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Image")
            detail("Description", meta.description)
            detail("Company", meta.company)
            detail("Version", meta.version)
            detail("Mapped Base", hex(id.loadAddress))
            detail("Size", ByteFormat.bytes(id.size))
            detail("Kind", id.isMappedFile ? "Mapped file" : "Dynamic library / framework")
        }
    }

    // MARK: Signature

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Signature")
            if loadingSignature {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying signature…").foregroundStyle(.secondary)
                }
            } else if let signature {
                detail("Signer", signature.signerDescription)
                if let team = signature.teamID, !team.isEmpty {
                    detail("Team ID", team)
                }
                if !signature.authority.isEmpty {
                    detail("Authority", signature.authority.joined(separator: " › "), scroll: true)
                }
                detail("Notarized", signature.isNotarized ? "Yes" : "No")
                if signature.isPlatformBinary { detail("Platform binary", "Yes") }
                if signature.isAdHoc { detail("Ad-hoc", "Yes") }
                if let sha = signature.sha256, !sha.isEmpty {
                    detail("SHA-256", sha, scroll: true)
                }
            } else {
                Text("Signature information is unavailable.")
                    .foregroundStyle(.secondary)
            }

            if let vtStatus {
                Text(vtStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!fileExists)

                Button {
                    runVirusTotal()
                } label: {
                    if vtBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("VirusTotal", systemImage: "checkmark.shield")
                    }
                }
                .disabled(vtBusy || (signature?.sha256?.isEmpty ?? true))

                if let link = vtPermalink, let url = URL(string: link) {
                    Link("Open report", destination: url)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String, scroll: Bool = false) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
                if scroll {
                    ScrollingValue(text: value, font: .callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hex(_ value: UInt64) -> String {
        value == 0 ? "—" : "0x" + String(value, radix: 16, uppercase: false)
    }

    // MARK: Actions

    private func loadSignature() async {
        loadingSignature = true
        let sig = await model.signing.signature(forPath: id.path)
        signature = sig
        loadingSignature = false
    }

    private func runVirusTotal() {
        guard let sha = signature?.sha256, !sha.isEmpty else { return }
        vtBusy = true
        vtStatus = "Querying VirusTotal…"
        vtPermalink = nil
        Task {
            do {
                if let result = try await model.signing.virusTotal(sha256: sha) {
                    vtStatus = "VirusTotal: \(result.positives)/\(result.total) engines flagged this file."
                    vtPermalink = result.permalink
                } else {
                    vtStatus = "VirusTotal: no report available (add an API key in Keychain, or the file is unknown)."
                }
            } catch {
                vtStatus = "VirusTotal lookup failed: \(error.localizedDescription)"
            }
            vtBusy = false
        }
    }
}
