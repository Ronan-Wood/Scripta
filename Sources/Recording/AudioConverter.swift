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
///
/// Conversion streams the source twice (peak pass, then gain-applied write) so memory stays
/// O(1 second of audio) regardless of recording length.
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

        // Pass 1: peak only.
        var sourcePeak: Float = 0
        try streamAsMono16k(url: inputURL, target: target) { buffer in
            guard let channel = buffer.floatChannelData else { return }
            for i in 0..<Int(buffer.frameLength) {
                let magnitude = abs(channel[0][i])
                if magnitude > sourcePeak { sourcePeak = magnitude }
            }
        }
        guard sourcePeak > silenceFloor else { return 0 }

        // Pass 2: re-convert, apply gain in place, write.
        let gain = targetPeak / sourcePeak
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        var writeError: Error?
        try streamAsMono16k(url: inputURL, target: target) { buffer in
            guard writeError == nil, let channel = buffer.floatChannelData else { return }
            for i in 0..<Int(buffer.frameLength) { channel[0][i] *= gain }
            do { try file.write(from: buffer) } catch { writeError = error }
        }
        if let writeError { throw writeError }

        return sourcePeak
    }

    /// Streams a source file as mono 16 kHz chunks (~1s each), downmixing/resampling on the
    /// fly. A missing file (e.g. no system audio was playing) yields nothing.
    private static func streamAsMono16k(
        url: URL, target: AVAudioFormat,
        handle: (AVAudioPCMBuffer) -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0, let converter = AVAudioConverter(from: source, to: target) else { return }

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

            if outputBuffer.frameLength > 0 { handle(outputBuffer) }

            if status == .endOfStream || status == .error { break }
        }
    }
}
