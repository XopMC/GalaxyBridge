import AudioToolbox
import CoreMedia
import Foundation

/// The live Android routes use raw AAC-LC access units plus AudioSpecificConfig.
/// No ADTS headers, PCE layouts, SBR/PS or implicit format guessing are admitted.
struct RecordingAACConfiguration: Equatable, Sendable {
    let audioSpecificConfig: Data
    let sampleRate: Int
    let channels: Int
    let framesPerPacket = 1024

    init(audioSpecificConfig: Data) throws {
        guard audioSpecificConfig.count == 2 else { throw ScreenRecorderError.audioConfiguration }
        let bytes = Array(audioSpecificConfig)
        let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let objectType = Int(bits >> 11)
        let rateIndex = Int((bits >> 7) & 15)
        let channels = Int((bits >> 3) & 15)
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        // GASpecificConfig: frameLengthFlag, dependsOnCoreCoder and extensionFlag all zero.
        guard objectType == 2, rateIndex < rates.count, (1...2).contains(channels), bits & 7 == 0 else {
            throw ScreenRecorderError.audioConfiguration
        }
        self.audioSpecificConfig = audioSpecificConfig.withUnsafeBytes { Data($0) }
        self.sampleRate = rates[rateIndex]
        self.channels = channels
    }

    func formatDescription() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        // MOV's esds atom requires the MPEG-4 ES/DecoderConfig descriptors, not the
        // two raw ASC bytes received from Android. Passing ASC directly creates a
        // writer-successful file whose audio track AVAssetReader cannot recognize.
        var cookie = Data([0x03, 0x19, 0x00, 0x01, 0x00, 0x04, 0x11, 0x40, 0x15,
                           0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x05, 0x02])
        cookie.append(audioSpecificConfig)
        cookie.append(contentsOf: [0x06, 0x01, 0x02])
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                layout: nil, magicCookieSize: bytes.count, magicCookie: bytes.baseAddress,
                extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw ScreenRecorderError.audioConfiguration }
        return format
    }

    func sample(_ payload: Data, pts: CMTime, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { throw ScreenRecorderError.audioPacket }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard copied == kCMBlockBufferNoErr else { throw ScreenRecorderError.audioPacket }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(framesPerPacket),
                                                  mDataByteSize: UInt32(payload.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: 1, presentationTimeStamp: pts,
            packetDescriptions: &packet, sampleBufferOut: &sample) == noErr, let sample else {
            throw ScreenRecorderError.audioPacket
        }
        return sample
    }
}
