import AVFoundation
import Foundation

enum AudioWaveformExtractor {
    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr,
              let buffer = UnsafeMutableAudioBufferListPointer(&audioBufferList).first,
              let data = buffer.mData else {
            return nil
        }

        let rms: Float
        let isFloat = (streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat {
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return nil }

            let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
            var sum: Float = 0
            for index in 0..<sampleCount {
                let sample = samples[index]
                sum += sample * sample
            }
            rms = sqrt(sum / Float(sampleCount))
        } else {
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { return nil }

            let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
            var sum: Float = 0
            for index in 0..<sampleCount {
                let sample = Float(samples[index]) / Float(Int16.max)
                sum += sample * sample
            }
            rms = sqrt(sum / Float(sampleCount))
        }

        return AudioWaveformNormalizer.normalizedWaveformLevel(from: rms)
    }
}

enum AudioWaveformNormalizer {
    static func normalizedWaveformLevel(from rms: Float) -> Float {
        let noiseFloor: Float = 0.008
        let ceiling: Float = 0.12
        let clamped = max(0, min(1, (rms - noiseFloor) / (ceiling - noiseFloor)))

        // Lift quiet speech while keeping louder sounds from pinning the meter.
        return pow(clamped, 0.5)
    }
}
