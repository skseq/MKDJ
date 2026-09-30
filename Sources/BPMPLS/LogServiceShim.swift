import Foundation
import os.log

/// Minimal stand-in for BPMPLS's LogService (which lives in that app's
/// AppServices.swift and is not lifted). The engine calls it ~26×; keeping
/// the call sites untouched minimizes the diff against the upstream engine.
final class LogService: @unchecked Sendable {
    static let shared = LogService()
    private let log = OSLog(subsystem: "com.sksoft.mkdj", category: "bpmpls")
    private init() {}
    func log(_ message: String) {
        os_log("%{public}@", log: log, type: .debug, message)
    }
}
