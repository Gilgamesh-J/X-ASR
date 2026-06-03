import CoreAudio
import Foundation

/// Enumerate macOS audio INPUT devices (microphones) so the user can pick a
/// specific one instead of always following the system default. We persist the
/// device UID (stable across reboots/reconnects, unlike the numeric AudioDeviceID).
enum AudioDevices {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// All devices that have at least one input channel.
    static func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = stringProp(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProp(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// Resolve a persisted UID back to a live AudioDeviceID (nil if unplugged).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                    alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProp(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard st == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
}
