import AVFoundation

/// Live master-bus recorder — arm/disarm toggle, 16-bit WAV of
/// exactly what you hear (master tap × master gain), saved on stop as
/// `YY.MMDD-hash-00m00s.wav` (per-recording random ID; duration stamped
/// at close via temp-name → rename, since the length is only known then).
final class EngineRecorder: @unchecked Sendable {

    static let shared = EngineRecorder()

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var tempURL: URL?
    private var startedAt: CFAbsoluteTime = 0
    private var framesWritten: AVAudioFramePosition = 0
    private(set) var lastSavedName: String?

    /// Max take length — the take auto-disarms (close + rename
    /// + KeepAwake release) when elapsed exceeds it. Internal access so
    /// test probes can gate the path cheaply.
    var maxRecordingSeconds: Double = 600

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return file != nil
    }

    var elapsedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard file != nil else { return 0 }
        return CFAbsoluteTimeGetCurrent() - startedAt
    }

    /// Default recordings home: ~/Documents/MKDJ Output (created on demand).
    static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("MKDJ Output", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func recordingsDirectory() -> URL {
        let path = UserDefaults.standard.string(forKey: "recordingsDirectory")
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return defaultDirectory()
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard file == nil else { return }
        let controller = AudioController.shared
        let format = controller.engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        let dir = Self.recordingsDirectory()
        let id = Self.randomID()
        let df = DateFormatter()
        df.dateFormat = "yy.MMdd"
        let stamp = df.string(from: Date())
        // temp name until the duration is known at stop
        let temp = dir.appendingPathComponent(".rec-\(stamp)-\(id).tmpwav")

        // 16-bit PCM WAV — the writing format converts from the tap's float
        let wavFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: format.sampleRate,
                                      channels: min(2, format.channelCount),
                                      interleaved: false) ?? format
        guard let out = try? AVAudioFile(forWriting: temp, settings: wavFormat.settings) else {
            MKLog.app("recorder: failed to create \(temp.path)", error: true)
            return
        }
        file = out
        tempURL = temp
        startedAt = CFAbsoluteTimeGetCurrent()
        framesWritten = 0

        controller.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096,
                                                   format: format) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock()
            let f = self.file
            self.lock.unlock()
            guard let f else { return }
            // master gain is applied at the mixer's outputVolume AFTER the
            // tap — multiply so the file carries what you hear
            let master = controller.engine.mainMixerNode.outputVolume
            let conv = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                        frameCapacity: buf.frameLength)
            guard let conv else { return }
            conv.frameLength = buf.frameLength
            let src = buf.floatChannelData!
            let dst = conv.floatChannelData!
            let ch = Int(min(buf.format.channelCount, f.processingFormat.channelCount))
            for c in 0..<ch {
                let s = src[c], d = dst[c]
                for i in 0..<Int(buf.frameLength) {
                    d[i] = s[i] * master
                }
            }
            try? f.write(from: conv)
            self.lock.lock()
            self.framesWritten += AVAudioFramePosition(buf.frameLength)
            let elapsed = CFAbsoluteTimeGetCurrent() - self.startedAt
            let over = self.file != nil && elapsed >= self.maxRecordingSeconds
            self.lock.unlock()
            if over {
                // 10-minute take cap. This is the AUDIO thread —
                // the disarm (file close + rename + KeepAwake) hops off it.
                DispatchQueue.main.async { self.stop() }
            }
        }
        MKLog.app("recorder: armed → \(temp.lastPathComponent)")
        KeepAwake.shared.setRecording(true)
    }

    func stop() {
        lock.lock()
        guard let f = file, let temp = tempURL else {
            lock.unlock()
            return
        }
        file = nil
        let frames = framesWritten
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        lock.unlock()

        AudioController.shared.engine.mainMixerNode.removeTap(onBus: 0)
        KeepAwake.shared.setRecording(false)
        // AVAudioFile has no explicit close — the handle flushes when `f`
        // deinits at this scope's end; hold it alive until after the tap
        // removal so no further writes race the flush
        let seconds = max(1, Int(elapsed.rounded()))
        let minutes = seconds / 60
        let final = temp.deletingLastPathComponent()
            .appendingPathComponent("\(tempStem(temp))-\(String(format: "%02dm%02ds", minutes, seconds % 60)).wav")
        do {
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: temp, to: final)
            lastSavedName = final.lastPathComponent
            MKLog.app(String(format: "recorder: saved %@ (%.1f s, %d frames)",
                              final.lastPathComponent, elapsed, frames))
        } catch {
            MKLog.app("recorder: rename failed — \(error.localizedDescription)", error: true)
        }
    }

    /// ".rec-26.0927-a3f9c2.tmpwav" → "26.0927-a3f9c2"
    private func tempStem(_ url: URL) -> String {
        let name = url.lastPathComponent
        guard name.hasPrefix(".rec-") else { return name }
        return String(name.dropFirst(5).dropLast(".tmpwav".count))
    }

    private static func randomID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
