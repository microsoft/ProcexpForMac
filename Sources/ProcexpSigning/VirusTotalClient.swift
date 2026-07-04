//
//  VirusTotalClient.swift
//  ProcexpSigning — W7
//
//  Actor that fronts the VirusTotal v3 file-reputation API. It owns:
//    • an in-memory + on-disk (JSON) cache keyed by SHA-256, and
//    • a token-bucket rate limiter (default 4 requests / minute).
//
//  Being an `actor` makes all of that state races-free and `Sendable`.
//

import Foundation
import ProcexpModel

/// Serialized VirusTotal client: cache + rate limiter + networking.
actor VirusTotalClient {
    /// Supplies the API key on demand (reads the Keychain). `nil` => unconfigured.
    private let apiKeyProvider: @Sendable () -> String?

    /// In-memory reputation cache. Mirrored to disk lazily.
    private var cache: [String: VirusTotalResult] = [:]
    private var didLoadCache = false

    /// Sliding window of recent request timestamps for the rate limiter.
    private var requestTimestamps: [Date] = []
    private let maxRequestsPerWindow: Int
    private let window: TimeInterval = 60

    /// On-disk cache location (may be nil if no caches dir is available).
    private let cacheURL: URL?

    init(maxRequestsPerMinute: Int = 4,
         apiKeyProvider: @escaping @Sendable () -> String?) {
        self.maxRequestsPerWindow = max(1, maxRequestsPerMinute)
        self.apiKeyProvider = apiKeyProvider

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = caches?
            .appendingPathComponent("com.sysinternals.procexpmac", isDirectory: true)
            .appendingPathComponent("virustotal-cache.json", isDirectory: false)
    }

    /// Returns a reputation result for `sha`, using the cache when possible.
    ///
    /// Returns `nil` when: no API key is configured, or the file is unknown to
    /// VirusTotal (HTTP 404). Throws `ProviderError.underlying` for genuine
    /// network / decoding failures.
    func result(forSHA256 sha: String) async throws -> VirusTotalResult? {
        loadCacheIfNeeded()

        if let cached = cache[sha] { return cached }

        guard let apiKey = apiKeyProvider() else { return nil }

        try await awaitRateLimitSlot()

        let result = try await fetch(sha: sha, apiKey: apiKey)
        if let result {
            cache[sha] = result
            persistCache()
        }
        return result
    }

    // MARK: - Networking

    private func fetch(sha: String, apiKey: String) async throws -> VirusTotalResult? {
        guard let url = URL(string: "https://www.virustotal.com/api/v3/files/\(sha)") else {
            throw ProviderError.underlying("Invalid VirusTotal URL for \(sha)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.underlying(String(describing: error))
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 404:
                // File not present in VT corpus — a valid "no data" answer.
                return nil
            default:
                throw ProviderError.underlying("VirusTotal HTTP \(http.statusCode)")
            }
        }

        let decoded: VTResponse
        do {
            decoded = try JSONDecoder().decode(VTResponse.self, from: data)
        } catch {
            throw ProviderError.underlying("VirusTotal decode failed: \(error)")
        }

        let stats = decoded.data.attributes.last_analysis_stats
        let positives = (stats["malicious"] ?? 0) + (stats["suspicious"] ?? 0)
        let total = stats.values.reduce(0, +)
        let permalink = "https://www.virustotal.com/gui/file/\(sha)"

        return VirusTotalResult(positives: positives,
                                total: total,
                                permalink: permalink,
                                checkedAt: Date())
    }

    // MARK: - Rate limiting (token bucket over a sliding 60s window)

    private func awaitRateLimitSlot() async throws {
        while true {
            let now = Date()
            // Drop timestamps outside the window.
            requestTimestamps.removeAll { now.timeIntervalSince($0) >= window }

            if requestTimestamps.count < maxRequestsPerWindow {
                requestTimestamps.append(now)
                return
            }

            // Sleep until the oldest in-window request ages out.
            if let oldest = requestTimestamps.first {
                let wait = window - now.timeIntervalSince(oldest)
                if wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
    }

    // MARK: - Cache persistence

    private func loadCacheIfNeeded() {
        guard !didLoadCache else { return }
        didLoadCache = true

        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: VirusTotalResult].self, from: data)
        else { return }
        cache = decoded
    }

    private func persistCache() {
        guard let url = cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - VirusTotal v3 response shape (only the fields we consume)

private struct VTResponse: Decodable {
    struct DataObject: Decodable {
        struct Attributes: Decodable {
            let last_analysis_stats: [String: Int]
        }
        let attributes: Attributes
    }
    let data: DataObject
}
