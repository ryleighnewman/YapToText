import AVFoundation

/// Decodes the audio of ANY media file - audio or video, in any container AVFoundation can read,
/// identified by CONTENT rather than file extension - into 16 kHz mono Float32 PCM buffers. Two
/// independent decode paths are tried so coverage is as wide as possible: the AVAssetReader path
/// (handles most containers and video tracks) and, as a fallback, the ExtAudioFile-based
/// AVAudioFile path (catches audio-only files the asset reader won't expose as a track, such as
/// some Voice Memos exports and raw/odd streams).
enum MediaAudioDecoder {
    static let outputSampleRate: Double = 16_000

    /// Feed each decoded chunk to `onChunk` (typically `engine.append`). Throws only if BOTH decode
    /// paths fail to produce any audio.
    static func decode(url: URL, onChunk: (AVAudioPCMBuffer) -> Void) async throws {
        // AVFoundation partly parses by extension, so a wrongly-named or extension-less file reads
        // as "no tracks". If that happens, sniff the real container from the magic bytes and retry
        // through a correctly-named temporary symlink. Both decode paths then use that URL.
        var readURL = url
        var asset = AVURLAsset(url: url)
        var track = try? await asset.loadTracks(withMediaType: .audio).first
        var tempLink: URL?
        if track == nil, let ext = sniffExtension(url: url) {
            let link = FileManager.default.temporaryDirectory
                .appendingPathComponent("yap-\(UUID().uuidString).\(ext)")
            if (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)) != nil {
                tempLink = link
                readURL = link
                asset = AVURLAsset(url: link)
                track = try? await asset.loadTracks(withMediaType: .audio).first
            }
        }
        defer { if let tempLink { try? FileManager.default.removeItem(at: tempLink) } }

        var emitted = 0
        func emit(_ buffer: AVAudioPCMBuffer) { emitted += 1; onChunk(buffer) }

        // Path 1: AVAssetReader.
        if let audioTrack = track {
            do {
                try readTrack(asset: asset, audioTrack: audioTrack, onChunk: emit)
                if emitted > 0 { return }
            } catch {
                // If it already emitted audio, don't re-run the fallback and double-feed the engine.
                if emitted > 0 { throw error }
            }
        }

        // Path 2: ExtAudioFile / AVAudioFile fallback.
        do {
            try decodeViaAudioFile(url: readURL, onChunk: onChunk)
        } catch {
            throw TranscriptionError.unavailable("No decodable audio was found in \(url.lastPathComponent).")
        }
    }

    // MARK: AVAssetReader path

    private static func readTrack(asset: AVURLAsset, audioTrack: AVAssetTrack,
                                  onChunk: (AVAudioPCMBuffer) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriptionError.unavailable("The audio track can't be decoded.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError.unavailable("Couldn't start reading the audio.")
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                                   channels: 1, interleaved: false)!
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            if let buffer = pcmBuffer(from: sample, format: format) { onChunk(buffer) }
            CMSampleBufferInvalidate(sample)
        }
        if reader.status == .failed {
            throw reader.error ?? TranscriptionError.unavailable("Failed while decoding the audio.")
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = CMSampleBufferGetNumSamples(sample)
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(numSamples), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    // MARK: AVAudioFile (ExtAudioFile) fallback

    /// Read the file with AVAudioFile and convert to 16 kHz mono Float32 on the fly. Handles the
    /// PCM/compressed audio formats ExtAudioFile supports (wav, aiff, caf, m4a/AAC/ALAC, mp3, flac),
    /// which covers Voice Memos and other audio-only files the asset reader may not expose.
    private static func decodeViaAudioFile(url: URL, onChunk: (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriptionError.unavailable("Couldn't set up audio conversion.")
        }

        var reachedEOF = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if reachedEOF { outStatus.pointee = .endOfStream; return nil }
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 8192) else {
                outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: inBuf) } catch { reachedEOF = true; outStatus.pointee = .endOfStream; return nil }
            if inBuf.frameLength == 0 { reachedEOF = true; outStatus.pointee = .endOfStream; return nil }
            outStatus.pointee = .haveData
            return inBuf
        }

        var producedAny = false
        while !reachedEOF {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                frameCapacity: AVAudioFrameCount(outputSampleRate)) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
            if let error { throw error }
            if outBuf.frameLength > 0 { onChunk(outBuf); producedAny = true }
            if status == .endOfStream || status == .error { break }
        }
        guard producedAny else { throw TranscriptionError.unavailable("The file had no readable audio.") }
    }

    // MARK: Container sniffing

    /// Identify a media container from its leading bytes so a mis-named file can be relinked with
    /// the right extension. Covers the common AVFoundation-decodable containers.
    private static func sniffExtension(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 12 else { return nil }
        let bytes = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String { String(bytes: bytes[range], encoding: .ascii) ?? "" }
        if ascii(4..<8) == "ftyp" { return "m4a" }        // MP4 / MOV / M4A / M4V / 3GP family (incl. Voice Memos)
        if ascii(0..<4) == "RIFF" { return "wav" }
        if ascii(0..<4) == "FORM" { return "aiff" }
        if ascii(0..<4) == "caff" { return "caf" }        // Core Audio Format
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<4) == "OggS" { return "ogg" }        // Ogg (Vorbis/Opus, where supported)
        if ascii(0..<5) == "#!AMR" { return "amr" }
        if ascii(0..<3) == "ID3"  { return "mp3" }
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "mp3" }   // MPEG audio frame sync
        return nil
    }
}
