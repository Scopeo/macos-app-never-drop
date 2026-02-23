@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let logger = Logger.app(category: "AudioCapture")

final class AudioCaptureManager: AudioSource, @unchecked Sendable {

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private var micEngine: AVAudioEngine?
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var monoSourceFormat: AVAudioFormat?
    private var sourceSampleRate: Double = 48_000
    private var currentOutputUID: String?

    private let lock = NSLock()
    private var systemSampleBuffer: [Float] = []
    private var micSampleBuffer: [Float] = []

    private let captureQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.AudioCapture", qos: .userInteractive)
    private let deviceListenerQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.DeviceListener")
    private let restartQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.DeviceRestart")
    private var inputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingRestartWork: DispatchWorkItem?
    private var engineConfigObserver: NSObjectProtocol?
    private(set) var isCapturing = false

    var onInputDeviceChanged: ((_ newDeviceID: AudioDeviceID) -> Void)?
    var onAggregateDeviceChanged: ((_ newAggregateID: AudioObjectID) -> Void)?

    static let targetSampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private static let maxBufferSamples = Int(60 * targetSampleRate)

    // MARK: - AudioSource

    var sampleRate: Double { Self.targetSampleRate }

    // MARK: - Public

    func startCapture() throws {
        guard !isCapturing else { return }

        // --- System audio: aggregate device with process tap (no mic) ---

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

        let outputUID = try readDefaultDeviceUID(scope: kAudioHardwarePropertyDefaultOutputDevice)
        currentOutputUID = outputUID

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NeverDrop-Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false,
                ],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
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
        let tapFmtErr = AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &tapDataSize, &tapStreamDesc)
        if tapFmtErr == noErr {
            sourceSampleRate = tapStreamDesc.mSampleRate
        }

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!
        monoSourceFormat = sourceFormat

        systemConverter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
        guard systemConverter != nil else {
            cleanup()
            throw AudioCaptureError.converterCreationFailed
        }

        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            captureQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudioBuffer(inInputData)
        }
        guard ioErr == noErr, let procID else {
            cleanup()
            throw AudioCaptureError.failedToCreateIOProc(ioErr)
        }
        ioProcID = procID

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            cleanup()
            throw AudioCaptureError.failedToStart(startErr)
        }

        // --- Mic audio: AVAudioEngine on default input ---

        do {
            try startMicEngine()
        } catch {
            cleanup()
            throw error
        }

        installDeviceChangeListeners()
        isCapturing = true
    }

    private func startMicEngine() throws {
        let engine = AVAudioEngine()
        micEngine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.cannotReadDevice(kAudioHardwareBadDeviceError)
        }

        let micSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: micSourceFormat, to: Self.targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        micConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        engine.prepare()
        try engine.start()

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.restartQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self, self.isCapturing else { return }
                if !(self.micEngine?.isRunning ?? false) {
                    self.restartMicEngine()
                }
            }
        }

        inputDeviceID = try readDefaultDeviceID(scope: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - Device change listeners

    private func installDeviceChangeListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let inBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleInputDeviceChanged()
        }
        inputListenerBlock = inBlock
        AudioObjectAddPropertyListenerBlock(systemObj, &inputAddr, deviceListenerQueue, inBlock)

        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChanged()
        }
        outputListenerBlock = outBlock
        AudioObjectAddPropertyListenerBlock(systemObj, &outputAddr, deviceListenerQueue, outBlock)
    }

    private func removeDeviceChangeListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        if let block = inputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, deviceListenerQueue, block)
            inputListenerBlock = nil
        }
        if let block = outputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, deviceListenerQueue, block)
            outputListenerBlock = nil
        }
    }

    private func handleInputDeviceChanged() {
        scheduleRestart(reason: "input")
    }

    private func handleOutputDeviceChanged() {
        scheduleRestart(reason: "output")
    }

    private func scheduleRestart(reason: String) {
        pendingRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performDebouncedRestart(reason: reason)
        }
        pendingRestartWork = work
        restartQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func performDebouncedRestart(reason: String) {
        guard isCapturing else { return }

        let newInputID = (try? readDefaultDeviceID(scope: kAudioHardwarePropertyDefaultInputDevice)) ?? kAudioObjectUnknown
        let inputChanged = newInputID != kAudioObjectUnknown && newInputID != inputDeviceID

        let newOutputUID = try? readDefaultDeviceUID(scope: kAudioHardwarePropertyDefaultOutputDevice)
        let outputChanged = newOutputUID != nil && newOutputUID != currentOutputUID

        if inputChanged {
            restartMicEngine()
            onInputDeviceChanged?(inputDeviceID)
        }

        if outputChanged {
            restartSystemCapture()
            onAggregateDeviceChanged?(aggregateDeviceID)
        }
    }

    private func restartMicEngine(retryCount: Int = 0) {
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micConverter = nil

        do {
            try startMicEngine()
        } catch {
            logger.error("Failed to restart mic engine after device change: \(error)")
            if retryCount < 3 {
                let nextRetry = retryCount + 1
                let delayMs = 500 * nextRetry
                restartQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                    guard let self, self.isCapturing else { return }
                    self.restartMicEngine(retryCount: nextRetry)
                }
            }
        }
    }

    private func restartSystemCapture() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        systemConverter = nil
        monoSourceFormat = nil

        do {
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tapUUID = UUID()
            tapDesc.uuid = tapUUID
            tapDesc.muteBehavior = .unmuted

            var newTapID: AudioObjectID = kAudioObjectUnknown
            let tapErr = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
            guard tapErr == noErr else { return }
            tapID = newTapID

            let outputUID = try readDefaultDeviceUID(scope: kAudioHardwarePropertyDefaultOutputDevice)
            currentOutputUID = outputUID

            let aggDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "NeverDrop-Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID,
                        kAudioSubDeviceDriftCompensationKey: false,
                    ],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUUID.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ],
                ],
            ]

            var newAggID: AudioObjectID = kAudioObjectUnknown
            let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
            guard aggErr == noErr else {
                AudioHardwareDestroyProcessTap(tapID)
                tapID = kAudioObjectUnknown
                return
            }
            aggregateDeviceID = newAggID

            var tapAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var tapStreamDesc = AudioStreamBasicDescription()
            var tapDataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let tapFmtErr = AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &tapDataSize, &tapStreamDesc)
            if tapFmtErr == noErr {
                sourceSampleRate = tapStreamDesc.mSampleRate
            }

            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            )!
            monoSourceFormat = sourceFormat
            systemConverter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)

            var procID: AudioDeviceIOProcID?
            let ioErr = AudioDeviceCreateIOProcIDWithBlock(
                &procID,
                aggregateDeviceID,
                captureQueue
            ) { [weak self] _, inInputData, _, _, _ in
                self?.handleAudioBuffer(inInputData)
            }
            guard ioErr == noErr, let procID else { return }
            ioProcID = procID
            AudioDeviceStart(aggregateDeviceID, procID)
        } catch {
            logger.error("Failed to restart system capture after output device change: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        cleanup()
    }

    func drainSystemSamples() -> [Float] {
        lock.lock()
        let samples = systemSampleBuffer
        systemSampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return samples
    }

    func drainMicSamples() -> [Float] {
        lock.lock()
        let samples = micSampleBuffer
        micSampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return samples
    }

    // MARK: - IO Callback (system audio only)

    private func handleAudioBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let systemConverter, let monoSourceFormat else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let bufCount = ablPtr.count
        guard bufCount > 0 else { return }

        let bytesPerSample = MemoryLayout<Float32>.size
        let firstBuf = ablPtr[0]
        let firstBufFrames = Int(firstBuf.mDataByteSize) / (bytesPerSample * Int(max(firstBuf.mNumberChannels, 1)))
        guard firstBufFrames > 0 else { return }

        let systemMono = downmixToMono(ablPtr, range: 0..<bufCount, frameCount: firstBufFrames)
        if let resampled = resample(systemMono, using: systemConverter, sourceFormat: monoSourceFormat) {
            lock.lock()
            systemSampleBuffer.append(contentsOf: resampled)
            if systemSampleBuffer.count > Self.maxBufferSamples {
                systemSampleBuffer.removeFirst(systemSampleBuffer.count - Self.maxBufferSamples)
            }
            lock.unlock()
        }
    }

    // MARK: - Mic callback (AVAudioEngine tap)

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let micConverter, let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channels = Int(buffer.format.channelCount)
        var mono: [Float]

        if channels == 1 {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            mono = [Float](repeating: 0, count: frameCount)
            for ch in 0..<channels {
                let ptr = channelData[ch]
                for f in 0..<frameCount { mono[f] += ptr[f] }
            }
            let scale = 1.0 / Float(channels)
            for f in 0..<frameCount { mono[f] *= scale }
        }

        if let resampled = resample(mono, using: micConverter, sourceFormat: micConverter.inputFormat) {
            lock.lock()
            micSampleBuffer.append(contentsOf: resampled)
            if micSampleBuffer.count > Self.maxBufferSamples {
                micSampleBuffer.removeFirst(micSampleBuffer.count - Self.maxBufferSamples)
            }
            lock.unlock()
        }
    }

    // MARK: - Audio helpers

    private func downmixToMono(
        _ ablPtr: UnsafeMutableAudioBufferListPointer,
        range: Range<Int>,
        frameCount: Int
    ) -> [Float] {
        let bytesPerSample = MemoryLayout<Float32>.size
        var monoMix = [Float](repeating: 0, count: frameCount)
        var buffersMixed = 0

        for i in range {
            let buf = ablPtr[i]
            let channels = Int(max(buf.mNumberChannels, 1))
            let frames = Int(buf.mDataByteSize) / (bytesPerSample * channels)
            let count = min(frames, frameCount)
            guard let data = buf.mData else { continue }

            let floatPtr = data.assumingMemoryBound(to: Float32.self)
            if channels == 1 {
                for f in 0..<count { monoMix[f] += floatPtr[f] }
            } else {
                for f in 0..<count {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += floatPtr[f * channels + ch] }
                    monoMix[f] += sum / Float(channels)
                }
            }
            buffersMixed += 1
        }

        if buffersMixed > 1 {
            let scale = 1.0 / Float(buffersMixed)
            for f in 0..<monoMix.count { monoMix[f] *= scale }
        }
        return monoMix
    }

    private func resample(
        _ mono: [Float],
        using converter: AVAudioConverter,
        sourceFormat: AVAudioFormat
    ) -> [Float]? {
        guard !mono.isEmpty else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)
        ) else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            inputBuffer.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }

        let ratio = Self.targetSampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat, frameCapacity: outputFrameCapacity
        ) else { return nil }

        converter.reset()

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !consumed else {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return nil }
        let outFrameCount = Int(outputBuffer.frameLength)
        guard outFrameCount > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: outFrameCount))
    }

    // MARK: - Cleanup

    private func cleanup() {
        removeDeviceChangeListeners()

        restartQueue.sync {
            self.pendingRestartWork?.cancel()
            self.pendingRestartWork = nil
        }

        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micConverter = nil
        inputDeviceID = kAudioObjectUnknown

        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        systemConverter = nil
        monoSourceFormat = nil
        currentOutputUID = nil
    }

    // MARK: - CoreAudio helpers

    private func readDefaultDeviceID(scope: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: scope,
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

    private func readDefaultDeviceUID(scope: AudioObjectPropertySelector) throws -> String {
        let deviceID = try readDefaultDeviceID(scope: scope)
        return try readDeviceUIDString(deviceID)
    }

    private func readDeviceUIDString(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard err == noErr else { throw AudioCaptureError.cannotReadDevice(err) }

        var uid: Unmanaged<CFString>?
        err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid)
        guard err == noErr, let cfStr = uid?.takeUnretainedValue() else {
            throw AudioCaptureError.cannotReadDevice(err)
        }
        return cfStr as String
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, CustomStringConvertible {
    case failedToCreateTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case invalidFormat
    case converterCreationFailed
    case failedToCreateIOProc(OSStatus)
    case failedToStart(OSStatus)
    case cannotReadDevice(OSStatus)

    var description: String {
        switch self {
        case .failedToCreateTap(let s): "Failed to create process tap (OSStatus \(s))"
        case .failedToCreateAggregateDevice(let s): "Failed to create aggregate device (OSStatus \(s))"
        case .invalidFormat: "Could not create AVAudioFormat from stream description"
        case .converterCreationFailed: "Could not create AVAudioConverter for resampling"
        case .failedToCreateIOProc(let s): "Failed to create IO proc (OSStatus \(s))"
        case .failedToStart(let s): "Failed to start audio device (OSStatus \(s))"
        case .cannotReadDevice(let s): "Cannot read audio device property (OSStatus \(s))"
        }
    }
}
