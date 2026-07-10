import XCTest
@testable import YapToText

final class HallucinationFilterTests: XCTestCase {
    func testStockPhrasesAreFiltered() {
        XCTAssertTrue(WhisperEngine.isSilenceHallucination("Thank you."))
        XCTAssertTrue(WhisperEngine.isSilenceHallucination(" thank you "))
        XCTAssertTrue(WhisperEngine.isSilenceHallucination("Thanks for watching!"))
        XCTAssertTrue(WhisperEngine.isSilenceHallucination("you"))
        XCTAssertTrue(WhisperEngine.isSilenceHallucination(""))
    }

    func testPeakWindowRMSSeparatesSilenceFromSpeech() {
        // 3 seconds of near-silence (mic noise floor): must be under the silence gate.
        let silence = (0..<48_000).map { _ in Float.random(in: -0.002...0.002) }
        XCTAssertLessThan(WhisperEngine.peakWindowRMS(silence), WhisperEngine.silenceRMS)

        // Same silence with one spoken word (0.4s tone burst in the middle): must pass the gate.
        var speech = silence
        for i in 20_000..<26_400 {
            speech[i] += 0.15 * sin(2 * .pi * 220 * Float(i) / 16_000)
        }
        XCTAssertGreaterThan(WhisperEngine.peakWindowRMS(speech), WhisperEngine.confidentSpeechRMS)
    }

    func testRealShortUtterancesSurvive() {
        XCTAssertFalse(WhisperEngine.isSilenceHallucination("Yes"))
        XCTAssertFalse(WhisperEngine.isSilenceHallucination("Stop"))
        XCTAssertFalse(WhisperEngine.isSilenceHallucination("Thank you, Sarah"))
        XCTAssertFalse(WhisperEngine.isSilenceHallucination("Okay"))
    }
}

final class AssistantResponseFilterTests: XCTestCase {
    func testAssistantRepliesAreCaught() {
        XCTAssertTrue(FoundationModelsTransformer.looksLikeAssistantResponse(
            "I understand your request, but I cannot comply. As an AI language model, I am designed to follow guidelines."))
        XCTAssertTrue(FoundationModelsTransformer.looksLikeAssistantResponse(
            "I'm happy to help! Please let me know how I can help you with your dictation."))
        XCTAssertTrue(FoundationModelsTransformer.looksLikeAssistantResponse(
            "Sure, here is the cleaned text. Is there anything else I can assist you with?"))
    }
    func testRealTranscriptsPassThrough() {
        XCTAssertFalse(FoundationModelsTransformer.looksLikeAssistantResponse(
            "Add some nice animations to the introduction screen when the app first launches."))
        XCTAssertFalse(FoundationModelsTransformer.looksLikeAssistantResponse(
            "Can you help me move the couch this weekend? Let me know if you're free."))
        XCTAssertFalse(FoundationModelsTransformer.looksLikeAssistantResponse("Buy milk and eggs."))
    }
}
