import XCTest
import AVFoundation
@testable import YapToText

/// True end-to-end inference test: feeds synthesized speech ("Hello world. This is a test of
/// the whisper engine.") through WhisperEngine with the tiny English model. Skips cleanly when
/// the fixtures aren't present, so CI without the 75MB model still passes.
final class WhisperEngineTests: XCTestCase {
    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YapToText/Models")
    }

    /// Exercises the 48kHz -> 16kHz converter branch of append(), i.e. the path REAL
    /// microphone input takes (the 16k test below bypasses conversion entirely).
    func testTranscribes48kHzInputThroughConverter() async throws {
        try await runEngine(audio: "whisper-test-48k.caf")
    }

    func testTranscribesSynthesizedSpeech() async throws {
        try await runEngine(audio: "whisper-test.caf")
    }

    private func runEngine(audio fixture: String) async throws {
        let modelURL = modelsDir.appendingPathComponent("ggml-tiny.en.bin")
        let audioURL = modelsDir.appendingPathComponent(fixture)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path)
                          && FileManager.default.fileExists(atPath: audioURL.path),
                          "whisper fixtures not installed")

        let engine = WhisperEngine(modelURL: modelURL, modelName: "Tiny (test)")
        let available = await engine.isAvailable()
        XCTAssertTrue(available)

        try await engine.beginSession(localeIdentifier: "en_US") { _ in }

        let file = try AVAudioFile(forReading: audioURL)
        let chunk = AVAudioFrameCount(4096)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            engine.append(buffer)
        }

        let text = try await engine.endSession()
        let lower = text.lowercased()
        // Tiny model on synthesized speech: exact wording can drift, but the anchors must land.
        XCTAssertTrue(lower.contains("hello"), "transcript was: \(text)")
        XCTAssertTrue(lower.contains("test"), "transcript was: \(text)")
    }
}
