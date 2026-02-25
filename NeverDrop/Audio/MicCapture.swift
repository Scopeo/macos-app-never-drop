@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let logger = Logger.app(category: "MicCapture")

final class MicCapture: @unchecked Sendable {

    private(set) var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    private let lock = NSLock()
    private var sampleBuffer: [Float] = []

    private let captureQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.MicCapture", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.MicListener")
    private let restartQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.MicRestart")
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingRestartWork: DispatchWorkItem?

    private(set) var isCapturing = false

    /// nil = follow system default; otherwise a specific device UID
    var selectedDeviceUID: String?

    var onDeviceChanged: ((_ newDeviceID: AudioDeviceID) -> Void)?

    private static let maxBufferSamples = Int(60 * AudioCaptureManager.targetSampleRate)

    // MARK: - Lifecycle

    func start() throws {
        guard !isCapturing else { return }
        let target = try resolveTargetDevice()
        try startCapture(on: target)
        installDefaultInputListener()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        removeDefaultInputListener()
        restartQueue.sync {
            self.pendingRestartWork?.cancel()
            self.pendingRestartWork = nil
        }
        teardown()
    }

    func drainSamples() -> [Float] {
        lock.lock()
        let samples = sampleBuffer
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return samples
    }

    /// Switch to a different device while capturing.
    func switchDevice(uid: String?) {
        selectedDeviceUID = uid
        guard isCapturing else { return }
        restartQueue.async { [weak self] in
            self?.performRestart()
        }
    }

    /// Pause the IOProc without tearing down (lightweight, for mic probe).
    func pauseIOProc() {
        guard let procID = ioProcID, deviceID != kAudioObjectUnknown else { return }
        AudioDeviceStop(deviceID, procID)
    }

    /// Resume a previously paused IOProc.
    func resumeIOProc() {
        guard let procID = ioProcID, deviceID != kAudioObjectUnknown else { return }
        AudioDeviceStart(deviceID, procID)
    }

    // MARK: - Capture on a specific device

    private func startCapture(on targetDeviceID: AudioDeviceID) throws {
        deviceID = targetDeviceID

        let format = try readInputStreamFormat(deviceID: targetDeviceID)
        sourceFormat = format

        guard let conv = AVAudioConverter(from: format, to: AudioCaptureManager.targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter = conv

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(
            &procID, targetDeviceID, captureQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleBuffer(inInputData)
        }
        guard err == noErr, let procID else {
            throw AudioCaptureError.failedToCreateIOProc(err)
        }
        ioProcID = procID

        let startErr = AudioDeviceStart(targetDeviceID, procID)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(targetDeviceID, procID)
            ioProcID = nil
            throw AudioCaptureError.failedToStart(startErr)
        }
    }

    private func teardown() {
        if let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
        }
        converter = nil
        sourceFormat = nil
        deviceID = kAudioObjectUnknown
    }

    // MARK: - Device resolution

    func resolveTargetDevice() throws -> AudioDeviceID {
        if let uid = selectedDeviceUID {
            if let id = Self.deviceIDForUID(uid) { return id }
            logger.warning("Selected mic UID '\(uid)' not found, falling back to system default")
        }
        return try Self.readDefaultInputDeviceID()
    }

    // MARK: - Default input listener

    private func installDefaultInputListener() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputChanged()
        }
        defaultInputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(systemObj, &addr, listenerQueue, block)
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListenerBlock else { return }
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(systemObj, &addr, listenerQueue, block)
        defaultInputListenerBlock = nil
    }

    private func handleDefaultInputChanged() {
        guard selectedDeviceUID == nil else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        pendingRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performRestart() }
        pendingRestartWork = work
        restartQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func performRestart(retryCount: Int = 0) {
        guard isCapturing else { return }
        let previousID = deviceID
        teardown()

        do {
            let target = try resolveTargetDevice()
            try startCapture(on: target)
            if deviceID != previousID {
                onDeviceChanged?(deviceID)
            }
        } catch {
            logger.error("Failed to restart mic capture: \(error)")
            if retryCount < 3 {
                let nextRetry = retryCount + 1
                restartQueue.asyncAfter(deadline: .now() + .milliseconds(500 * nextRetry)) { [weak self] in
                    guard let self, self.isCapturing else { return }
                    self.performRestart(retryCount: nextRetry)
                }
            }
        }
    }

    // MARK: - IO callback

    private func handleBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let sourceFormat else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let bufCount = ablPtr.count
        guard bufCount > 0 else { return }

        let bytesPerSample = MemoryLayout<Float32>.size
        let firstBuf = ablPtr[0]
        let firstBufFrames = Int(firstBuf.mDataByteSize) / (bytesPerSample * Int(max(firstBuf.mNumberChannels, 1)))
        guard firstBufFrames > 0 else { return }

        let mono = AudioHelpers.downmixToMono(ablPtr, range: 0..<bufCount, frameCount: firstBufFrames)

        if let resampled = AudioHelpers.resample(mono, using: converter, sourceFormat: sourceFormat) {
            lock.lock()
            sampleBuffer.append(contentsOf: resampled)
            if sampleBuffer.count > Self.maxBufferSamples {
                sampleBuffer.removeFirst(sampleBuffer.count - Self.maxBufferSamples)
            }
            lock.unlock()
        }
    }

    // MARK: - CoreAudio helpers

    private func readInputStreamFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            throw AudioCaptureError.cannotReadDevice(kAudioHardwareBadDeviceError)
        }

        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 48_000
        var srSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, nil, &srSize, &sampleRate)

        guard sampleRate > 0 else {
            throw AudioCaptureError.cannotReadDevice(kAudioHardwareBadDeviceError)
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        return format
    }

    private static func readDefaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard err == noErr else { throw AudioCaptureError.cannotReadDevice(err) }
        return deviceID
    }

    static func deviceIDForUID(_ targetUID: String) -> AudioDeviceID? {
        for id in MicrophoneMonitor.allInputDeviceIDs() {
            if deviceUID(id) == targetUID { return id }
        }
        return nil
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid) == noErr,
              let cfStr = uid?.takeUnretainedValue() else { return nil }
        return cfStr as String
    }
}
