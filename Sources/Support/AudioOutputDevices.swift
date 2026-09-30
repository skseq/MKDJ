import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// CoreAudio output-device enumeration + AVAudioEngine assignment.
/// `AVAudioEngine.outputDeviceID` is deprecated but functional on current
/// macOS — the only supported way to pick an output device for the engine
/// without tearing the graph down around an AUGraph.
enum AudioOutputDevices {

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID          // 0 reserved for "system default"
        let name: String
        let isSystemDefault: Bool
    }

    /// All devices with output streams, system default first.
    static func list() -> [Device] {
        var devices: [Device] = []

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var data_size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &data_size) == noErr,
              data_size > 0 else { return devices }
        let count = Int(data_size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &data_size, &ids) == noErr else {
            return devices
        }

        let defaultID = systemDefaultID()
        for id in ids where hasOutputStreams(id) {
            devices.append(Device(id: id, name: name(of: id),
                                  isSystemDefault: id == defaultID))
        }
        // stable order: default first, then by name
        devices.sort { a, b in
            if a.isSystemDefault != b.isSystemDefault { return a.isSystemDefault }
            return a.name < b.name
        }
        return devices
    }

    static func systemDefaultID() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else {
            return "Device \(id)"
        }
        return name as String
    }

    /// Is the persisted device present right now?
    static func deviceExists(_ id: AudioDeviceID) -> Bool {
        list().contains { $0.id == id }
    }

    /// Hot-plug watcher — if the chosen output device disappears
    /// (unplugged DAC, Bluetooth), fall back to the system default with one
    /// log line, IINA-style.
    static func installHotplugWatcher(onLoss: @escaping (String) -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let retained = Unmanaged.passRetained(HotplugContext(onLoss: onLoss))
        let opaque = retained.toOpaque()
        // C function-pointer context: capture-free trampoline over `opaque`.
        let trampoline: @convention(c) (AudioObjectID, UInt32,
                                        UnsafePointer<AudioObjectPropertyAddress>,
                                        UnsafeMutableRawPointer?) -> OSStatus = { _, _, _, clientData in
            guard let clientData else { return noErr }
            Unmanaged<HotplugContext>.fromOpaque(clientData).takeUnretainedValue().fire()
            return noErr
        }
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &address, trampoline, opaque)
    }

    private final class HotplugContext {
        let onLoss: (String) -> Void
        init(onLoss: @escaping (String) -> Void) { self.onLoss = onLoss }
        var lastFire = Date.distantPast
        func fire() {
            // hardware listeners fire for ANY device change — debounce,
            // then check only whether OUR device survived.
            guard Date().timeIntervalSince(lastFire) > 0.5 else { return }
            lastFire = Date()
            DispatchQueue.main.async { [onLoss] in
                let id = AppSettings.shared.outputDeviceID
                guard id != 0, !deviceExists(AudioDeviceID(id)) else { return }
                let name = AppSettings.shared.outputDeviceName
                onLoss(name.isEmpty ? "device \(id)" : name)
            }
        }
    }

    /// Point the engine at a device (nil = system default). Sets the HAL
    /// device on the output AudioUnit (kAudioOutputUnitProperty_CurrentDevice)
    /// — the old AVAudioEngine.outputDeviceID property no longer exists in
    /// the SDK. The engine stops/starts around the change; the caller
    /// resumes decks.
    @discardableResult
    static func apply(to engine: AVAudioEngine, deviceID: AudioDeviceID?) -> Bool {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        var target = deviceID ?? systemDefaultID()
        let outputAU = engine.outputNode.audioUnit
        var ok = false
        if let au = outputAU {
            let status = AudioUnitSetProperty(au,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &target, UInt32(MemoryLayout<AudioDeviceID>.size))
            ok = status == noErr
        }
        if wasRunning {
            do {
                try engine.start()
            } catch {
            // A silent restart failure here killed the whole
            // graph with no trail
                MKLog.app("engine restart after device change FAILED: \(error.localizedDescription)", error: true)
            }
        }
        return ok
    }
}
