import Foundation

// SkipList — per-Move skip list mechanism.
//
// Each Move (6a, 6b, 6c) can have a list of file paths that the rule should NOT
// fire on, even if the conditions are met. This is the per-Move mechanism for
// handling false positives without killing the rule globally.
//
// Storage: JSON file at ~/Library/Application Support/BPMPLS/skip_lists.json
// Schema: { "move6a": ["/path/to/file1.mp3", ...], "move6b": [...], "move6c": [...] }
//
// The skip list is loaded once at first access and cached. The user edits the
// JSON manually; edits are picked up on the next app launch.

enum MoveID: String {
    case move6a   // chunk-vote ratio for ×3/2-low (fold-UP only)
    case move6b   // grid-stability fold-DOWN (×2/×3/2)
    case move6c   // ×2/×½ family extension to Move 4 cross-band
}

struct SkipLists: Codable {
    var move6a: [String] = []
    var move6b: [String] = []
    var move6c: [String] = []

    static let empty = SkipLists()

    /// Path to the on-disk JSON file. Created lazily.
    static var filePath: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("BPMPLS", isDirectory: true)
        return dir.appendingPathComponent("skip_lists.json")
    }

    /// Load from disk. Returns empty if the file doesn't exist or is malformed.
    static func load() -> SkipLists {
        let path = filePath
        guard let data = try? Data(contentsOf: path) else { return .empty }
        let dec = JSONDecoder()
        return (try? dec.decode(SkipLists.self, from: data)) ?? .empty
    }

    /// Check if a given path is in the skip list for a Move.
    func isSkipped(path: String, for move: MoveID) -> Bool {
        let list: [String]
        switch move {
        case .move6a: list = move6a
        case .move6b: list = move6b
        case .move6c: list = move6c
        }
        return list.contains { $0 == path }
    }
}

/// Thread-safe accessor. SkipLists is loaded once per process and shared.
final class SkipListStore {
    static let shared = SkipListStore()

    private let lock = NSLock()
    private var lists: SkipLists

    private init() {
        self.lists = SkipLists.load()
    }

    func isSkipped(path: String, for move: MoveID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lists.isSkipped(path: path, for: move)
    }
}
