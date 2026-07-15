import AVFoundation

/// Converts a raw capture track into the 16 kHz mono 16-bit PCM WAV that the transcription
/// engine consumes. One WAV per track (mic, system) so each can be transcribed separately for
/// speaker attribution — the split is physical (mic = "You", system = "Them"), not an ML guess.
///
/// Conversion is done offline after the session stops. Each track is peak-normalized so a
/// quietly-recorded source still transcribes well; near-silent tracks are left untouched so we
/// don't amplify their noise floor.
///
/// v1 limitations (acceptable for transcription, noted for later):
/// - Both tracks are treated as starting at t=0; sub-100ms start skew between them is ignored.
/// - The converted track is held in memory before writing (~115 MB per recorded hour).
enum AudioConverter {
    private static let targetSampleRate = 16_000.0
    private static let targetPeak: Float = 0.7
    private static let silenceFloor: Float = 0.02

    /// Converts one source track to a 16 kHz mono WAV at `outputURL` and returns the source's
    /// pre-gain peak amplitude (0 if the file is missing, empty, or effectively silent). Callers
    /// use the peak to decide whether the track carried real speech worth transcribing. When the
    /// peak is below the silence floor, nothing is written and 0 is returned.
    @discardableResult
    static func prepareTrack(inputURL: URL, outputURL: URL) throws -> Float {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            throw NSError(domain: "CallTranscriber", code: 200,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the target audio format."])
        }

        var samples = try loadAsMono16k(url: inputURL, target: target)
        let sourcePeak = peak(of: samples)
        guard sourcePeak > silenceFloor else { return 0 }

        let gain = targetPeak / sourcePeak
        for i in samples.indices { samples[i] *= gain }

        try writeWAV(samples: samples, sampleRate: targetSampleRate, url: outputURL)
        return sourcePeak
    }

    private static func peak(of samples: [Float]) -> Float {
        var maxValue: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > maxValue { maxValue = magnitude }
        }
        return maxValue
    }

    /// Reads a source file, downmixing to mono and resampling to 16 kHz. A missing file
    /// (e.g. no system audio was playing) is treated as silence.
    private static func loadAsMono16k(url: URL, target: AVAudioFormat) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0, let converter = AVAudioConverter(from: source, to: target) else { return [] }

        var samples = [Float]()
        let outputCapacity = AVAudioFrameCount(targetSampleRate)   // 1s of output per pass

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else { break }
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError { throw conversionError }

            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let channel = outputBuffer.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
            }

            if status == .endOfStream || status == .error { break }
        }

        return samples
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let chunkSize = 16_000

        var offset = 0
        while offset < samples.count {
            let frames = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { source in
                channel[0].update(from: source.baseAddress!.advanced(by: offset), count: frames)
            }
            try file.write(from: buffer)
            offset += frames
        }
    }
}
