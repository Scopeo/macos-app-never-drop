@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum AudioHelpers {

    static func downmixToMono(
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

    static func resample(
        _ mono: [Float],
        using converter: AVAudioConverter,
        sourceFormat: AVAudioFormat
    ) -> [Float]? {
        guard !mono.isEmpty else { return nil }

        let targetFormat = AudioCaptureManager.targetFormat

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)
        ) else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            inputBuffer.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(mono.count) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputFrameCapacity
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
}
