import CoreAudio
import Foundation

final class MicrophoneMonitor: MicrophoneMonitoring, @unchecked Sendable {

    private var trackedDevices = Set<AudioDeviceID>()
    private var listenerBlocks = [AudioDeviceID: AudioObjectPropertyListenerBlock]()
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastStatus: Bool?
    private let queue = DispatchQueue(label: "com.draftnrun.NeverDrop.MicMonitor")

    deinit {
        queue.sync { stopMonitoring() }
    }

    // MARK: - MicrophoneMonitoring

    func statusStream() -> AsyncStream<Bool> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            self.queue.sync {
                self.continuation = continuation
                self.startMonitoring()
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.stopMonitoring() }
            }
        }
    }

    // MARK: - Monitoring lifecycle

    private func startMonitoring() {
        setupDeviceListListener()
        refreshDevices()
        checkAndEmit()
    }

    private func stopMonitoring() {
        for deviceID in trackedDevices {
            removeRunningListener(for: deviceID)
        }
        if let block = deviceListListenerBlock {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, block)
            deviceListListenerBlock = nil
        }
        trackedDevices.removeAll()
        listenerBlocks.removeAll()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Device list listener (hot-plug)

    private func setupDeviceListListener() {
        var address = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
            self?.checkAndEmit()
        }
        deviceListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, block)
    }

    // MARK: - Per-device running listener

    private func refreshDevices() {
        let currentInputIDs = Set(Self.allInputDeviceIDs())

        for id in trackedDevices.subtracting(currentInputIDs) {
            removeRunningListener(for: id)
        }
        for id in currentInputIDs.subtracting(trackedDevices) {
            addRunningListener(for: id)
        }
        trackedDevices = currentInputIDs
    }

    private func addRunningListener(for deviceID: AudioDeviceID) {
        var address = Self.isRunningAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkAndEmit()
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
            listenerBlocks[deviceID] = block
        }
    }

    private func removeRunningListener(for deviceID: AudioDeviceID) {
        guard let block = listenerBlocks.removeValue(forKey: deviceID) else { return }
        var address = Self.isRunningAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
    }

    // MARK: - Status check

    private func checkAndEmit() {
        let current = trackedDevices.contains { Self.isDeviceRunning($0) }
        if lastStatus != current {
            lastStatus = current
            continuation?.yield(current)
        }
    }

    // MARK: - CoreAudio helpers

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var isRunningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = devicesAddress
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return [] }
        return deviceIDs
    }

    static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, data) == noErr
        else { return false }

        let bufferList = data.assumingMemoryBound(to: AudioBufferList.self).pointee
        return bufferList.mNumberBuffers > 0
    }

    static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isRunning) == noErr
        else { return false }
        return isRunning != 0
    }

    static func allInputDeviceIDs() -> [AudioDeviceID] {
        allDeviceIDs().filter { hasInputStreams($0) }
    }
}
