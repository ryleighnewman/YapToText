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

// Every string below was taken from the dictation history between 2026-09-12 and 2026-09-16,
// where each one reached the History page and, for most, the cursor.
final class SpeakerLabelHistoryTests: XCTestCase {
    func testOneWordNameLabelAtStart() {
        XCTAssertEqual(WhisperEngine.stripNameLabels("Ryleigh: Huge congratulations. I wish you all the best."),
                       "Huge congratulations. I wish you all the best.")
    }
    func testNameWithMidWordCapital() {
        XCTAssertEqual(WhisperEngine.stripNameLabels("Neil DeGrasse: The latest screenshot is in that room."),
                       "The latest screenshot is in that room.")
    }
    func testNameWithDigitRepeatedMidText() {
        XCTAssertEqual(WhisperEngine.stripNameLabels("Guy 2: I still see the noise. Guy 2: You can identify it."),
                       "I still see the noise. You can identify it.")
    }
    func testSpeakerLabelAfterSentenceEnd() {
        XCTAssertEqual(WhisperEngine.stripSpeakerLabels("I am not greedy. Speaker 1: Accessibility shortcut."),
                       "I am not greedy. Accessibility shortcut.")
    }
    func testPhoneticDriftOfPrimedNameIsKnown() {
        let names = WhisperEngine.primeNames("Ryleigh, iPhone, YapToText.")
        XCTAssertEqual(WhisperEngine.stripNameLabels("Ryleigh: Why did you connect to GitHub.", knownNames: names),
                       "Why did you connect to GitHub.")
    }
    func testHeadingShapedDictationIsKept() {
        XCTAssertEqual(WhisperEngine.stripNameLabels("Note: buy milk and eggs today."), "Note: buy milk and eggs today.")
        XCTAssertEqual(WhisperEngine.stripNameLabels("Step 2: open the settings page."), "Step 2: open the settings page.")
        XCTAssertEqual(WhisperEngine.stripNameLabels("Subject: the meeting on Friday."), "Subject: the meeting on Friday.")
    }
    func testLeadingStageDirections() {
        XCTAssertEqual(WhisperEngine.stripLeadingStageDirection("*computer voice* You must remove the parts of the update screen."),
                       "You must remove the parts of the update screen.")
        XCTAssertEqual(WhisperEngine.stripLeadingStageDirection("*Glielp* I made an Anki plugin that edits the binding."),
                       "I made an Anki plugin that edits the binding.")
        XCTAssertEqual(WhisperEngine.stripLeadingStageDirection("*Best of the camera* Right now it appears that certain menus break."),
                       "Right now it appears that certain menus break.")
    }
    func testLeadingPhoneNumberInParenthesesIsKept() {
        XCTAssertEqual(WhisperEngine.stripLeadingStageDirection("(555) 123 4567 is the office line."),
                       "(555) 123 4567 is the office line.")
    }
    func testPrimeHasNoLabelShape() {
        XCTAssertFalse("Ryleigh, iPhone, YapToText.".contains(":"))
    }
}

// Cleanup drops, every case from the 2026-09-16 history. The words come back, fillers stay gone.
final class CleanupDroppedWordsTests: XCTestCase {
    func testDroppedAsideComesBack() {
        let raw = "Before I do that, I notice that on my previous message, for example, he doesn't actually put down everything I say."
        let cleaned = "Before I do that, I notice that on my previous message, he doesn't actually put down everything I say."
        let r = DictationController.restoreDroppedWords(in: cleaned, from: raw)
        XCTAssertEqual(r.text, raw)
        XCTAssertEqual(r.restored, ["for example,"])
    }
    func testDroppedSentenceComesBack() {
        let raw = "The app stopped working as soon as the device was connected. The app just could not listen to me anymore. It was refusing to work."
        let cleaned = "The app stopped working as soon as the device was connected. It was refusing to work."
        let r = DictationController.restoreDroppedWords(in: cleaned, from: raw)
        XCTAssertEqual(r.text, raw)
    }
    func testDroppedProfanityComesBack() {
        let raw = "Don't stop working, just keep fucking fixing everything."
        let cleaned = "Don't stop working, just keep fixing everything."
        XCTAssertEqual(DictationController.restoreDroppedWords(in: cleaned, from: raw).text, raw)
    }
    func testFillersAndStuttersMayGo() {
        let raw = "Um, so I I want to, you know, open the the settings page, like, now."
        let cleaned = "I want to open the settings page now."
        let r = DictationController.restoreDroppedWords(in: cleaned, from: raw)
        XCTAssertEqual(r.text, cleaned)
        XCTAssertTrue(r.restored.isEmpty)
    }
    func testCorrectionsAreNotDrops() {
        let raw = "Puraging some stuff that we don't need. And we are working on the X-Pendid River."
        let cleaned = "Purging some stuff that we don't need. And we are working on the XPendid River."
        let r = DictationController.restoreDroppedWords(in: cleaned, from: raw)
        XCTAssertEqual(r.text, cleaned)
        XCTAssertTrue(r.restored.isEmpty)
    }
    func testMovedWordsAreNotDrops() {
        let raw = "Tomorrow I will call you. I promise."
        let cleaned = "I will call you tomorrow. I promise."
        XCTAssertTrue(DictationController.restoreDroppedWords(in: cleaned, from: raw).restored.isEmpty)
    }
}

final class ReplaceEditTests: XCTestCase {
    func testLiteralSwapFromTheLog() {
        XCTAssertEqual(ReplaceEdit.apply(instruction: "Change this to named.", to: "different"), "named")
        XCTAssertEqual(ReplaceEdit.apply(instruction: "replace it with renamed", to: "Different"), "Renamed")
        XCTAssertEqual(ReplaceEdit.apply(instruction: "change this to say hello there", to: "goodbye,"), "hello there,")
        XCTAssertEqual(ReplaceEdit.apply(instruction: "swap that for API", to: "SDK"), "API")
    }
    func testRewritesStillGoToTheModel() {
        XCTAssertNil(ReplaceEdit.apply(instruction: "change this to a question", to: "You are coming"))
        XCTAssertNil(ReplaceEdit.apply(instruction: "change this to Spanish", to: "good morning"))
        XCTAssertNil(ReplaceEdit.apply(instruction: "change this to bullet points", to: "one two three"))
        XCTAssertNil(ReplaceEdit.apply(instruction: "make it shorter", to: "different"))
        XCTAssertNil(ReplaceEdit.apply(instruction: "change this to past tense", to: "I go"))
        XCTAssertNil(ReplaceEdit.apply(instruction: "change this to something better", to: "This whole sentence is long and rambling here"))
    }
}

final class AdaptReplacingTests: XCTestCase {
    func testLowercaseWordMidSentence() {
        XCTAssertEqual(InsertionContext.adaptReplacing("Hearing aids.", selection: "feelings"), "hearing aids")
        XCTAssertEqual(InsertionContext.adaptReplacing("I think so.", selection: "feelings"), "I think so")
        XCTAssertEqual(InsertionContext.adaptReplacing("NASA.", selection: "feelings"), "NASA")
    }
    func testSelectionKeepsItsOwnMarkAndSpaces() {
        XCTAssertEqual(InsertionContext.adaptReplacing("hearing aids", selection: "feelings,"), "hearing aids,")
        XCTAssertEqual(InsertionContext.adaptReplacing("Hearing aids.", selection: "feelings "), "hearing aids ")
        XCTAssertEqual(InsertionContext.adaptReplacing("we went home", selection: "That was the end."), "We went home.")
        XCTAssertEqual(InsertionContext.adaptReplacing("Is it done", selection: "Are we there?"), "Is it done?")
    }
}
