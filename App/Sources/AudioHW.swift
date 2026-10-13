import CoreAudio
import Foundation

/// Helpers finos sobre a API de propriedades do CoreAudio.
enum AudioHW {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func get<T>(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = address
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return st == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &v) { AudioObjectSetPropertyData(obj, &a, 0, nil, size, $0) } == noErr
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let s = ref else { return nil }
        return s.takeRetainedValue() as String
    }

    static func uid(_ dev: AudioDeviceID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }
    static func name(_ dev: AudioDeviceID) -> String? { string(dev, kAudioObjectPropertyName) }

    static func deviceIDs() -> [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Resolve um UID para o ID do dispositivo (funciona também para dispositivos ocultos).
    static func device(uid: String) -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return st == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    static func channelCount(_ dev: AudioDeviceID, input: Bool) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration,
                     input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: dispositivo padrão

    enum Role { case output, input, system }

    private static func selector(_ role: Role) -> AudioObjectPropertySelector {
        switch role {
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .system: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }

    static func defaultDevice(_ role: Role) -> AudioDeviceID? {
        get(system, addr(selector(role)), AudioDeviceID(0))
    }

    @discardableResult
    static func setDefaultDevice(_ role: Role, _ dev: AudioDeviceID) -> Bool {
        set(system, addr(selector(role)), dev)
    }

    // MARK: volume / mute

    private static func scope(input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    static func volume(_ dev: AudioDeviceID, input: Bool) -> Float? {
        get(dev, addr(kAudioDevicePropertyVolumeScalar, scope(input: input)), Float32(0))
    }

    static func setVolume(_ dev: AudioDeviceID, input: Bool, _ v: Float) {
        set(dev, addr(kAudioDevicePropertyVolumeScalar, scope(input: input)), Float32(max(0, min(1, v))))
    }

    static func isMuted(_ dev: AudioDeviceID, input: Bool) -> Bool {
        (get(dev, addr(kAudioDevicePropertyMute, scope(input: input)), UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ dev: AudioDeviceID, input: Bool, _ m: Bool) {
        set(dev, addr(kAudioDevicePropertyMute, scope(input: input)), UInt32(m ? 1 : 0))
    }

    static func isRunningSomewhere(_ dev: AudioDeviceID) -> Bool {
        (get(dev, addr(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
    }

    static func nominalSampleRate(_ dev: AudioDeviceID) -> Float64? {
        get(dev, addr(kAudioDevicePropertyNominalSampleRate), Float64(0))
    }

    static func setNominalSampleRate(_ dev: AudioDeviceID, _ rate: Float64) {
        set(dev, addr(kAudioDevicePropertyNominalSampleRate), rate)
    }

    // MARK: listeners

    final class Listener {
        let obj: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        init(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
            self.obj = obj
            self.address = address
            self.block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(obj, &self.address, DispatchQueue.main, block)
        }
        deinit { AudioObjectRemovePropertyListenerBlock(obj, &address, DispatchQueue.main, block) }
    }
}
