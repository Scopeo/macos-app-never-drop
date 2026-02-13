@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let logger = Logger.app(category: "AudioCapture")

final class AudioCaptureManager: AudioSource, @unchecked Sendable {

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var monoSourceFormat: AVAudioFormat?
    private var sourceSampleRate: Double = 48_000
    private var tapChannelCount: Int = 2
    private var micBuffersFirst = false

    private let lock = NSLock()
    private var systemSampleBuffer: [Float] = []
    private var micSampleBuffer: [Float] = []
    private var didLogBufferLayout = false

    private let captureQueue = DispatchQueue(label: "com.draftnrun.NeverDrop.AudioCapture", qos: .userInteractive)
    private(set) var isCapturing = false

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
        let inputUID = try readDefaultDeviceUID(scope: kAudioHardwarePropertyDefaultInputDevice)

        let outputRate = try readDeviceSampleRate(uid: outputUID)
        let inputRate = try readDeviceSampleRate(uid: inputUID)
        let masterUID = inputRate <= outputRate ? inputUID : outputUID
        micBuffersFirst = (masterUID == inputUID)

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NeverDrop-Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: masterUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: true,
                ],
                [
                    kAudioSubDeviceUIDKey: inputUID,
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
            tapChannelCount = Int(tapStreamDesc.mChannelsPerFrame)
        }

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!
        monoSourceFormat = sourceFormat

        systemConverter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
        micConverter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
        if systemConverter == nil || micConverter == nil {
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

        didLogBufferLayout = false
        isCapturing = true
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

    // MARK: - IO Callback

    private func handleAudioBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let systemConverter, let micConverter, let monoSourceFormat else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let bufCount = ablPtr.count
        guard bufCount > 0 else { return }

        let bytesPerSample = MemoryLayout<Float32>.size
        let firstBuf = ablPtr[0]
        let firstBufFrames = Int(firstBuf.mDataByteSize) / (bytesPerSample * Int(max(firstBuf.mNumberChannels, 1)))
        guard firstBufFrames > 0 else { return }

        let micRange: Range<Int>
        let systemRange: Range<Int>

        if micBuffersFirst {
            var tapStart = bufCount
            var tapChannelsFound = 0
            for i in stride(from: bufCount - 1, through: 0, by: -1) {
                tapChannelsFound += Int(max(ablPtr[i].mNumberChannels, 1))
                tapStart = i
                if tapChannelsFound >= tapChannelCount { break }
            }
            micRange = 0..<tapStart
            systemRange = tapStart..<bufCount
        } else {
            var tapEnd = 0
            var tapChannelsFound = 0
            for i in 0..<bufCount {
                tapChannelsFound += Int(max(ablPtr[i].mNumberChannels, 1))
                tapEnd = i + 1
                if tapChannelsFound >= tapChannelCount { break }
            }
            systemRange = 0..<tapEnd
            micRange = tapEnd..<bufCount
        }

        if !didLogBufferLayout {
            didLogBufferLayout = true
            var desc = "IO buffer layout: \(bufCount) buffers, tapCh=\(tapChannelCount), micFirst=\(micBuffersFirst)."
            for i in 0..<bufCount { desc += " buf[\(i)]: \(ablPtr[i].mNumberChannels)ch" }
            desc += " → mic=\(micRange), sys=\(systemRange)"
            logger.info("\(desc)")
        }

        if !systemRange.isEmpty {
            let systemMono = downmixToMono(ablPtr, range: systemRange, frameCount: firstBufFrames)
            if let resampled = resample(systemMono, using: systemConverter, sourceFormat: monoSourceFormat) {
                lock.lock()
                systemSampleBuffer.append(contentsOf: resampled)
                if systemSampleBuffer.count > Self.maxBufferSamples {
                    systemSampleBuffer.removeFirst(systemSampleBuffer.count - Self.maxBufferSamples)
                }
                lock.unlock()
            }
        }

        if !micRange.isEmpty {
            let micMono = downmixToMono(ablPtr, range: micRange, frameCount: firstBufFrames)
            if let resampled = resample(micMono, using: micConverter, sourceFormat: monoSourceFormat) {
                lock.lock()
                micSampleBuffer.append(contentsOf: resampled)
                if micSampleBuffer.count > Self.maxBufferSamples {
                    micSampleBuffer.removeFirst(micSampleBuffer.count - Self.maxBufferSamples)
                }
                lock.unlock()
            }
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

        let ratio = Self.targetSampleRate / sourceSampleRate
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
        micConverter = nil
        monoSourceFormat = nil
    }

    // MARK: - CoreAudio helpers

    private func readDefaultDeviceUID(scope: AudioObjectPropertySelector) throws -> String {
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

        return try readDeviceUIDString(deviceID)
    }

    private func readDeviceSampleRate(uid: String) throws -> Double {
        let deviceID = try deviceIDForUID(uid)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard err == noErr else { throw AudioCaptureError.cannotReadDevice(err) }
        return sampleRate
    }

    private func deviceIDForUID(_ targetUID: String) throws -> AudioDeviceID {
        let allDevices = MicrophoneMonitor.allDeviceIDs()
        for deviceID in allDevices {
            if let uid = try? readDeviceUIDString(deviceID), uid == targetUID {
                return deviceID
            }
        }
        throw AudioCaptureError.cannotReadDevice(kAudioHardwareBadDeviceError)
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
