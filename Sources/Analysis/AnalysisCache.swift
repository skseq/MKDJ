import Foundation

/// Invisible per-track analysis cache in Application Support:
/// BPM, grid anchor, confidence flags and the waveform peak pyramid.
/// Keyed on file path + modification time + size; a changed file re-analyzes.
struct CachedAnalysis: Codable {
    var version: Int = 3
    var path: String
    var mtime: Double
    var size: Int64
    var sampleRate: Double
    var analyzedSeconds: Double
    var bpm: Double
    var anchorSeconds: Double
    var confidence: Double
    var noBeatFound: Bool
    var multiTempo: Bool
    var peaks: PeakPyramid
    /// Beat times (source seconds) for tap-anchor snapping.
    var beatTimes: [Double] = []
    /// v2 fields (optionals so v1 caches decode cleanly).
    var analyzer: String? = nil        // "v2-cross" | "v2" | "v1-fallback"
    var sections: [GridEstimator.Section]? = nil
}

final class AnalysisCache {

    static let shared = AnalysisCache()

    let directory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appendingPathComponent("MKDJ/AnalysisCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// FNV-1a 64 of path|mtime|size, hex — filename-safe cache key.
    /// Analyzer generation — part of the cache key. Any change to
    /// estimator/arbitration semantics bumps this and every old cache entry
    /// misses, so on-load can never serve a verdict from an older analyzer
    /// (the "load said 80.4, MKDJ button said 121.95" class of bug).
    /// g3 = support gate, metrical relatives, hybrid arbitration.
    static let analyzerGeneration = "g4"   // v3 single-engine (DP-decides + octave-fold)

    private func key(for url: URL) -> String {
        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = Int64(attrs?.fileSize ?? 0)
        let input = "\(Self.analyzerGeneration)|\(url.path)|\(String(format: "%.0f", mtime))|\(size)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    func load(url: URL) -> CachedAnalysis? {
        let fileURL = directory.appendingPathComponent(key(for: url) + ".json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedAnalysis.self, from: data)
    }

    /// Budget-aware store — after writing, evict least-recently-used
    /// entries (mtime) until the directory fits the configured budget.
    /// The just-written file is never evicted (touch it first so a budget
    /// squeeze evicts older entries ahead of it).
    func store(_ analysis: CachedAnalysis, url: URL) {
        let fileURL = directory.appendingPathComponent(key(for: url) + ".json")
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: fileURL, options: .atomic)
        }
        evictToBudget(protecting: fileURL)
    }

    private func entries() -> [(url: URL, size: Int64, mtime: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return files.compactMap { f in
            let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (f, Int64(rv?.fileSize ?? 0), rv?.contentModificationDate ?? .distantPast)
        }
    }

    func totalSizeBytes() -> Int64 {
        entries().reduce(Int64(0)) { $0 + $1.size }
    }

    private func evictToBudget(protecting protected: URL?) {
        // store() runs on a background task — read the budget straight from
        // defaults (no actor hop); AppSettings persists this same key.
        let limitMB = UserDefaults.standard.object(forKey: "analysisCacheLimitMB") as? Int ?? 1024
        let budget = Int64(limitMB) * 1024 * 1024
        var all = entries().sorted { $0.mtime < $1.mtime }   // oldest first
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        while total > budget, let oldest = all.first {
            if oldest.url == protected {
                // never evict the fresh write; treat it as newest
                all.removeFirst()
                all.append(oldest)
                if all.count <= 1 { break }
                continue
            }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            all.removeFirst()
        }
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
