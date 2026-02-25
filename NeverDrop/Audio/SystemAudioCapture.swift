@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let logger = Logger.app(category: "SystemAudio")

final class SystemAudioCapture: @unchecked Sendable {

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private var converter: AVAudioConverter?
    private var monoSourceFormat: AVAudioFormat?
    private var sourceSampleRate: Double = 48_000
    private var currentOutputUID: String?

    private let lock = NSLock()
    private var sampleBuffer: [Float] = []

    private let captureQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.SystemCapture", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.SystemListener")
    private let restartQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.SystemRestart")
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingRestartWork: DispatchWorkItem?

    private(set) var isCapturing = false

    private static let maxBufferSamples = Int(60 * AudioCaptureManager.targetSampleRate)

    // MARK: - Lifecycle

    func start() throws {
        guard !isCapturing else { return }

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapUUID = UUID()
        tapDesc.uuid = tapUUID
        tapDesc.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapErr == noErr else {
            throw AudioCaptureError.failedToCreateTap(tapErr)
        }
        tapID = newTapID

        let outputUID = try Self.readDefaultDeviceUID()
        currentOutputUID = outputUID

        try buildAggregateAndStart(outputUID: outputUID)
        installOutputListener()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        removeOutputListener()
        restartQueue.sync {
            self.pendingRestartWork?.cancel()
            self.pendingRestartWork = nil
        }
        teardownIOProc()
        teardownAggregate()
        teardownTap()
        converter = nil
        monoSourceFormat = nil
        currentOutputUID = nil
    }

    func drainSamples() -> [Float] {
        lock.lock()
        let samples = sampleBuffer
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return samples
    }

    // MARK: - Build pipeline

    private func buildAggregateAndStart(outputUID: String) throws {
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NeverDrop-Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: false],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggErr == noErr else {
            throw AudioCaptureError.failedToCreateAggregateDevice(aggErr)
        }
        aggregateDeviceID = newAggID

        var tapAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapStreamDesc = AudioStreamBasicDescription()
        var tapDataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &tapDataSize, &tapStreamDesc) == noErr {
            sourceSampleRate = tapStreamDesc.mSampleRate
        }

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false
        )!
        monoSourceFormat = sourceFormat
        converter = AVAudioConverter(from: sourceFormat, to: AudioCaptureManager.targetFormat)
        guard converter != nil else { throw AudioCaptureError.converterCreationFailed }

        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateDeviceID, captureQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleBuffer(inInputData)
        }
        guard ioErr == noErr, let procID else { throw AudioCaptureError.failedToCreateIOProc(ioErr) }
        ioProcID = procID

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else { throw AudioCaptureError.failedToStart(startErr) }
    }

    // MARK: - Output device listener

    private func installOutputListener() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart()
        }
        outputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(systemObj, &addr, listenerQueue, block)
    }

    private func removeOutputListener() {
        guard let block = outputListenerBlock else { return }
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(systemObj, &addr, listenerQueue, block)
        outputListenerBlock = nil
    }

    private func scheduleRestart() {
        pendingRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performRestart() }
        pendingRestartWork = work
        restartQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func performRestart() {
        guard isCapturing else { return }
        let newUID = try? Self.readDefaultDeviceUID()
        guard let newUID, newUID != currentOutputUID else { return }

        teardownIOProc()
        teardownAggregate()
        teardownTap()
        converter = nil
        monoSourceFormat = nil

        do {
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tapUUID = UUID()
            tapDesc.uuid = tapUUID
            tapDesc.muteBehavior = .unmuted
            var newTapID: AudioObjectID = kAudioObjectUnknown
            guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr else { return }
            tapID = newTapID

            currentOutputUID = newUID
            try buildAggregateAndStart(outputUID: newUID)
        } catch {
            logger.error("Failed to restart system capture: \(error)")
        }
    }

    // MARK: - IO callback

    private func handleBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let monoSourceFormat else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let bufCount = ablPtr.count
        guard bufCount > 0 else { return }

        let bytesPerSample = MemoryLayout<Float32>.size
        let firstBuf = ablPtr[0]
        let firstBufFrames = Int(firstBuf.mDataByteSize) / (bytesPerSample * Int(max(firstBuf.mNumberChannels, 1)))
        guard firstBufFrames > 0 else { return }

        let mono = AudioHelpers.downmixToMono(ablPtr, range: 0..<bufCount, frameCount: firstBufFrames)

        if let resampled = AudioHelpers.resample(mono, using: converter, sourceFormat: monoSourceFormat) {
            lock.lock()
            sampleBuffer.append(contentsOf: resampled)
            if sampleBuffer.count > Self.maxBufferSamples {
                sampleBuffer.removeFirst(sampleBuffer.count - Self.maxBufferSamples)
            }
            lock.unlock()
        }
    }

    // MARK: - Teardown

    private func teardownIOProc() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
    }

    private func teardownAggregate() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
    }

    private func teardownTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - CoreAudio helpers

    private static func readDefaultDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard err == noErr else { throw AudioCaptureError.cannotReadDevice(err) }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize: UInt32 = 0
        var uidErr = AudioObjectGetPropertyDataSize(deviceID, &uidAddr, 0, nil, &uidSize)
        guard uidErr == noErr else { throw AudioCaptureError.cannotReadDevice(uidErr) }
        var uid: Unmanaged<CFString>?
        uidErr = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        guard uidErr == noErr, let cfStr = uid?.takeUnretainedValue() else {
            throw AudioCaptureError.cannotReadDevice(uidErr)
        }
        return cfStr as String
    }
}
