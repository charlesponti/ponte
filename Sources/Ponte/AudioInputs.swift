import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// One audio input the machine offers. Identified by CoreAudio's UID, not by its name: "ponti.pods" becomes
/// "AirPods Pro" between one OS release and the next, and a pin has to survive that.
struct AudioInput: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }
}

/// Which microphone a take comes from.
///
/// The engine Ponte records through (`AVAudioEngine`) follows the *system* default input, and has no API for saying
/// otherwise. The one honest way in is the input node's underlying audio unit: `kAudioOutputUnitProperty_CurrentDevice`
/// on it is how every macOS recorder picks a device. Setting it has to happen before the input node is first
/// touched, which is why Ponte now owns the `AVAudioEngine` and injects it into the shared recorder.
enum AudioInputs {

    /// Every device with at least one input stream, in the order CoreAudio lists them.
    static func available() -> [AudioInput] {
        allDeviceIDs().compactMap { id in
            guard inputChannels(of: id) > 0,
                  let uid = string(of: id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(of: id, kAudioObjectPropertyName) ?? uid
            return AudioInput(uid: uid, name: name)
        }
    }

    static func systemDefaultUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &deviceID) == noErr, deviceID != 0 else { return nil }
        return string(of: deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// What to record from, and whether a pin had to be abandoned.
    ///
    /// Pure, so the fallback has a test rather than a hope: a pinned device that is not connected must never look
    /// like a pin that is working, and the caller is told so it can say as much in the window.
    static func resolve(pinned: String?, available: [AudioInput],
                        defaultUID: String?) -> (input: AudioInput?, fellBack: Bool) {
        if let pinned, let match = available.first(where: { $0.uid == pinned }) {
            return (match, false)
        }
        let fallback = available.first { $0.uid == defaultUID } ?? available.first
        return (fallback, pinned != nil)
    }

    /// Ask the engine's input audio unit to record from this device. Must be called before the input node is touched.
    @discardableResult
    static func apply(_ input: AudioInput, to engine: AVAudioEngine) -> Bool {
        guard let deviceID = deviceID(forUID: input.uid) else { return false }
        guard let unit = engine.inputNode.audioUnit else { return false }
        // Uninitialise before repointing: the unit then re-reads the device's hardware format when it is initialised
        // again, instead of holding the previous device's rate.
        AudioUnitUninitialize(unit)
        var id = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { return false }
        // Prepare the graph so AVAudioEngine picks the new hardware format up before the recorder installs its tap.
        engine.prepare()
        return true
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string(of: $0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// What the engine's input unit says it is using — asked of the unit, not remembered from what we asked for.
    /// Logging the request instead of the effect is how a pin that never took looks like a pin that worked.
    static func currentDevice(of engine: AVAudioEngine) -> (uid: String?, name: String)? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID, &size)
        guard status == noErr, deviceID != 0 else { return (nil, "unreadable") }
        let uid = string(of: deviceID, kAudioDevicePropertyDeviceUID)
        return (uid, string(of: deviceID, kAudioObjectPropertyName) ?? "unknown")
    }

    /// Which inputs the hardware is running right now. The honest oracle for "is this take really coming from that
    /// microphone", where a property we set is only a request.
    static func runningInputNames() -> [String] {
        allDeviceIDs().compactMap { id in
            guard inputChannels(of: id) > 0 else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr, running != 0 else {
                return nil
            }
            return string(of: id, kAudioObjectPropertyName)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(of device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
