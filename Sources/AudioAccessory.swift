import Foundation
import CoreAudio

struct AudioOutputDescriptor {
    enum Transport { case builtIn, bluetooth, bluetoothLE, usb, other }
    let transport: Transport
    let dataSource: UInt32?
    let terminalTypes: [UInt32]
    let name: String
}

enum HeadphoneClassification {
    /// HAL does not expose a reliable headset category for every Bluetooth device.
    /// Recognized model names complement explicit port metadata; unknown stays off.
    static func isHeadphones(_ output: AudioOutputDescriptor?) -> Bool {
        guard let output else { return false }
        if output.dataSource == 0x6864706e || output.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return true // IOKit 'hdpn' output selection or CoreAudio headphone terminal.
        }
        guard output.transport == .bluetooth || output.transport == .bluetoothLE else { return false }
        let name = String(output.name.prefix(256)).lowercased()
        if ["speaker", "soundbar", "homepod", "колонк"].contains(where: name.contains) { return false }
        return ["airpods", "headphone", "headset", "earbud", "наушник", "powerbeats", "beats fit",
                "beats studio", "beats solo", "beats flex", "beats buds", "quietcomfort", "bose qc",
                "wh-1000", "wf-1000", "wh-ch", "wf-c"].contains(where: name.contains)
    }
}

protocol AudioOutputObserving: AnyObject {
    func start(onChange: @escaping (AudioOutputDescriptor?) -> Void)
    func stop()
}

/// Optional, event-driven decoration. No recording sessions, microphone access,
/// playback inspection, device names on disk, timers, or Bluetooth connections.
final class HeadphoneAccessoryController {
    private let observer: AudioOutputObserving
    private(set) var isEnabled = false
    private(set) var isWearingHeadphones = false
    var onChange: ((Bool) -> Void)?

    init(observer: AudioOutputObserving = NativeAudioOutputObserver()) { self.observer = observer }
    deinit { observer.stop() }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        guard enabled else { observer.stop(); apply(false); return }
        observer.start { [weak self] output in
            guard let self, self.isEnabled else { return }
            self.apply(HeadphoneClassification.isHeadphones(output))
        }
    }

    private func apply(_ wearing: Bool) {
        guard isWearingHeadphones != wearing else { return }
        isWearingHeadphones = wearing
        onChange?(wearing)
    }
}

/// CoreAudio property listeners are attached only while the preference is on.
/// All callbacks are delivered on the main queue; all queries concern output only.
final class NativeAudioOutputObserver: AudioOutputObserving {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var outputID: AudioObjectID = kAudioObjectUnknown
    private var outputStreams: [AudioObjectID] = []
    private var onChange: ((AudioOutputDescriptor?) -> Void)?
    deinit { stop() }

    func start(onChange: @escaping (AudioOutputDescriptor?) -> Void) {
        stop()
        self.onChange = onChange
        if let listener = listen(object: AudioObjectID(kAudioObjectSystemObject),
                                 selector: kAudioHardwarePropertyDefaultOutputDevice) {
            systemListeners.append(listener)
        }
        refresh()
    }

    func stop() {
        remove(&systemListeners); remove(&deviceListeners)
        onChange = nil; outputID = kAudioObjectUnknown; outputStreams = []
    }

    private func refresh() {
        guard let onChange else { return }
        let device = readUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
            ?? kAudioObjectUnknown
        let streams = device == kAudioObjectUnknown ? [] : readStreams(device)
        if outputID != device || outputStreams != streams {
            remove(&deviceListeners)
            outputID = device; outputStreams = streams
            if device != kAudioObjectUnknown {
                for selector in [kAudioDevicePropertyDataSource, kAudioDevicePropertyStreams] {
                    if let listener = listen(object: device, selector: selector, scope: kAudioDevicePropertyScopeOutput) {
                        deviceListeners.append(listener)
                    }
                }
                for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyTransportType] {
                    if let listener = listen(object: device, selector: selector) { deviceListeners.append(listener) }
                }
                for stream in streams {
                    if let listener = listen(object: stream, selector: kAudioStreamPropertyTerminalType) {
                        deviceListeners.append(listener)
                    }
                }
            }
        }
        guard device != kAudioObjectUnknown,
              readUInt32(device, kAudioDevicePropertyDeviceIsAlive) == 1 else { onChange(nil); return }
        let transport: AudioOutputDescriptor.Transport
        switch readUInt32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth: transport = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: transport = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: transport = .usb
        default: transport = .other
        }
        onChange(AudioOutputDescriptor(transport: transport,
            dataSource: readUInt32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
            terminalTypes: streams.compactMap { readUInt32($0, kAudioStreamPropertyTerminalType) },
            name: readName(device) ?? ""))
    }

    private func listen(object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Listener? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listeners: inout [Listener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners.removeAll()
    }

    private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private func readStreams(_ object: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size <= 64 * MemoryLayout<AudioObjectID>.size,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(streams.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }

    private func readName(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pointer: UnsafeRawPointer?
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pointer) == noErr,
              let pointer else { return nil }
        // CoreAudio transfers ownership of CFString properties to the caller.
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }
}
