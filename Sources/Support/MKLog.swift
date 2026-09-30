import Foundation

/// Rolling app log: in-memory ring for the Diagnostics window +
/// capped file at ~/Library/Logs/MKDJ.log. Categories: app, keys, beep, engine.
final class MKLog {

    static let shared = MKLog()

    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("MKDJ.log")

    private let q = DispatchQueue(label: "MKDJ.log")
    private var ring: [String] = []
    private var fileStreak = 0   // stat the file for rotation only occasionally
    private let maxBytes = 5_000_000

    private init() {
        try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    // MARK: Categories

    static func app(_ message: String, error: Bool = false) {
        shared.log(error ? "ERROR" : "app", message)
    }
    static func keys(_ message: String) { shared.log("keys", message) }
    static func beep(_ message: String) { shared.log("beep", message) }
    static func engine(_ message: String) { shared.log("engine", message) }

    /// Last lines, oldest first (Diagnostics window).
    var recent: [String] { q.sync { ring } }

    func log(_ category: String, _ message: String) {
        let line = "\(Self.stamp()) [\(category)] \(message)"
        q.async {
            self.ring.append(line)
            if self.ring.count > 800 { self.ring.removeFirst(self.ring.count - 800) }
            self.write(line)
        }
    }

    /// Cached formatter — a new DateFormatter per line was the
    /// log path's dominant cost.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func stamp() -> String {
        stampFormatter.string(from: Date())
    }

    private var fileHandle: FileHandle?

    private func write(_ line: String) {
        fileStreak += 1
        if fileStreak > 200 {
            fileStreak = 0
            if let size = (try? FileManager.default.attributesOfItem(atPath: Self.logURL.path))?[.size] as? Int,
               size > maxBytes {
                try? FileManager.default.removeItem(at: Self.logURL.appendingPathExtension("1"))
                try? FileManager.default.moveItem(at: Self.logURL, to: Self.logURL.appendingPathExtension("1"))
            }
        }
        // Persistent handle (open once, seek+write per line) —
        // open/close per line was file-I/O per log record
        let data = (line + "\n").data(using: .utf8)!
        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: Self.logURL.path) {
                FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            }
            fileHandle = FileHandle(forWritingAtPath: Self.logURL.path)
        }
        if let h = fileHandle {
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: Self.logURL)
        }
    }
}
