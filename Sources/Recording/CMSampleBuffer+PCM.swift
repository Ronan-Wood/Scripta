import AVFoundation
import CoreMedia

extension CMSampleBuffer {
    /// Copies this audio sample buffer's PCM data into a new `AVAudioPCMBuffer`
    /// matching the buffer's own stream format. Returns nil for non-audio or empty buffers.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }
}
