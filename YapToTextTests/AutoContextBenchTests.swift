import XCTest
@testable import YapToText

/// The Auto mode bench: every deterministic layer of the auto pipeline, table-driven and broad.
/// (The live-model gauntlet lives in LLMGauntletTests.)
final class AutoContextBenchTests: XCTestCase {

    // MARK: Heuristic screen

    func testCasualStaysAsSpoken() {
        let cases = [
            "What's up man?",
            "hey man you coming tonight",
            "lol that was wild",
            "yo dude the game was insane haha",
            "omg no way",
            "sup",
            "on my way",
            "sounds good thanks",
        ]
        for text in cases {
            XCTAssertEqual(AutoContext.screen(text), .message, "should stay as spoken: \(text)")
        }
    }

    func testObviousEmailsRouteToEmail() {
        let cases = [
            "Dear Jessica, how are you today? Please send me that file when you can. Thank you, Ryleigh.",
            "Hi Marcus, I am writing to follow up on our conversation from Tuesday. Please let me know when you have a moment. Best regards, Ryleigh",
            "Hello team, please find attached the quarterly numbers. Looking forward to hearing your thoughts. Kind regards, Ryleigh",
            "Dear support, I wanted to reach out about my order which has not arrived. Please let me know the status. Thanks, Ryleigh",
        ]
        for text in cases {
            XCTAssertEqual(AutoContext.screen(text), .email, "should be email: \(text.prefix(40))")
        }
    }

    func testMediumProseGetsCleanup() {
        let text = "So I was thinking about the project timeline and I feel like we need to move the deadline back about a week because the testing phase is taking longer than we expected"
        XCTAssertEqual(AutoContext.screen(text), .cleanup)
    }

    func testEmptyAndWhitespaceAreMessages() {
        XCTAssertEqual(AutoContext.screen(""), .message)
        XCTAssertEqual(AutoContext.screen("   \n  "), .message)
    }

    func testLongMixedSignalTextIsAmbiguous() {
        // 70+ words with one email tell: too uncertain for the heuristic, should defer.
        let long = Array(repeating: "the meeting covered a range of topics including budget staffing and the roadmap", count: 9).joined(separator: " ") + " please let me know"
        XCTAssertNil(AutoContext.screen(long))
    }

    // MARK: Destination bias

    func testDestinationBias() {
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.microsoft.Outlook"), .email)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.apple.MobileSMS"), .message)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.hnc.Discord"), .message)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.tinyspeck.slackmacgap"), .message)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.apple.Terminal"), .code)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "com.apple.Notes"), .note)
        XCTAssertEqual(AutoContext.destinationBias(bundleID: "md.obsidian"), .note)
        XCTAssertNil(AutoContext.destinationBias(bundleID: "com.example.unknown"))
        XCTAssertNil(AutoContext.destinationBias(bundleID: nil))
    }

    // MARK: Trailing directives

    func testDirectivesAreDetectedAndStripped() {
        let cases: [(input: String, remainder: String)] = [
            ("Tell John the deadline moved, make that formal", "Tell John the deadline moved"),
            ("We shipped the fix this morning. Make it concise.", "We shipped the fix this morning."),
            ("Grocery run milk eggs bread, as a bullet list please", "Grocery run milk eggs bread"),
            ("Thanks for the help yesterday, make it more friendly", "Thanks for the help yesterday"),
            ("Meeting notes from today, as a note", "Meeting notes from today"),
        ]
        for c in cases {
            let result = AutoContext.extractDirective(c.input)
            XCTAssertNotNil(result, "directive missed: \(c.input)")
            XCTAssertEqual(result?.text, c.remainder, "wrong remainder for: \(c.input)")
            XCTAssertFalse(result?.directive.isEmpty ?? true)
        }
    }

    func testDirectiveMidSentenceDoesNotTrigger() {
        // "make it formal" NOT at the end is content, not a command.
        let cases = [
            "I want to make it formal before we send it to legal next week",
            "She said to make it concise but I disagree with her about that",
        ]
        for text in cases {
            XCTAssertNil(AutoContext.extractDirective(text), "false positive: \(text)")
        }
    }

    func testDirectiveAloneDoesNotStripToNothing() {
        // If the whole dictation IS the directive, there is no content left - must not fire.
        XCTAssertNil(AutoContext.extractDirective("make it formal"))
    }

    // MARK: Recipient

    func testRecipientDetection() {
        XCTAssertEqual(AutoContext.recipient(in: "Dear Jessica, how are you today?"), "Jessica")
        XCTAssertEqual(AutoContext.recipient(in: "hi marcus, quick question about the invoice"), "Marcus")
        XCTAssertEqual(AutoContext.recipient(in: "Hello D'Angelo, following up on the quote."), "D'Angelo")
        XCTAssertNil(AutoContext.recipient(in: "The dear old house was on a hill"))
        XCTAssertNil(AutoContext.recipient(in: "hi how are you"))   // greeting with no name+comma
    }

    // MARK: AI verdict parsing

    func testAIVerdictParsing() {
        XCTAssertEqual(AutoContext.verdict(fromAI: "EMAIL"), .email)
        XCTAssertEqual(AutoContext.verdict(fromAI: " email.\n"), .email)
        XCTAssertEqual(AutoContext.verdict(fromAI: "MESSAGE"), .message)
        XCTAssertEqual(AutoContext.verdict(fromAI: "Note"), .note)
        XCTAssertEqual(AutoContext.verdict(fromAI: "CLEANUP"), .cleanup)
        XCTAssertEqual(AutoContext.verdict(fromAI: "total nonsense"), .cleanup)   // safe default
    }

    // MARK: Sanitizer (the model-output backstop)

    func testSanitizeStripsMidTextPreambleAndEcho() {
        // The exact failure seen in the wild: echoed input, then a preamble, then the body,
        // then the app name the model mistook for a signature.
        let raw = """
        I was wondering if you could send me that email by 2pm please, thank you.

        Here is the rewritten email body:

        I was wondering if you could send me that email by 2pm please, thank you.
        """
        let out = FoundationModelsTransformer.sanitize(raw)
        XCTAssertEqual(out, "I was wondering if you could send me that email by 2pm please, thank you.")
    }

    func testSanitizeStripsLeadingPreamble() {
        XCTAssertEqual(FoundationModelsTransformer.sanitize("Sure, here's the cleaned text:\nHello world."),
                       "Hello world.")
    }

    func testSanitizeStripsSubjectAndQuotes() {
        XCTAssertEqual(FoundationModelsTransformer.sanitize("Subject: Hello\n\nBody text here."), "Body text here.")
        XCTAssertEqual(FoundationModelsTransformer.sanitize("\"Quoted output.\""), "Quoted output.")
    }

    func testSanitizeLeavesCleanTextAlone() {
        let clean = "Just a normal sentence. And another one here."
        XCTAssertEqual(FoundationModelsTransformer.sanitize(clean), clean)
    }

    func testSanitizeDoesNotEatLegitimateColonLines() {
        // A real dictation can contain a colon line that is NOT a preamble.
        let text = "Agenda for tomorrow:\nBudget review and hiring plan."
        XCTAssertEqual(FoundationModelsTransformer.sanitize(text), text)
    }

    // MARK: App-name signature scrub (the deterministic layer that makes the leak impossible)

    func testStripLeakedAppNameExactFieldFailure() {
        // The verbatim output the user received.
        let leaked = "Dear Jessica,\n\nPlease send the email by 3 p.m.\n\nThank you.\n\nClaude"
        let out = FoundationModelsTransformer.stripLeakedAppName(leaked, appName: "Claude")
        XCTAssertEqual(out, "Dear Jessica,\n\nPlease send the email by 3 p.m.\n\nThank you.")
    }

    func testStripLeakedAppNameVariants() {
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName("Body text.\n\n-- Claude", appName: "Claude"),
                       "Body text.")
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName("Body text.\nclaude", appName: "Claude"),
                       "Body text.")
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName("Body text.\n\nClaude\n\n", appName: "Claude"),
                       "Body text.")
    }

    func testStripLeavesInlineMentionsAndOtherNamesAlone() {
        let inline = "I asked Claude about the schedule and it helped."
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName(inline, appName: "Claude"), inline)
        let signedByUser = "Thanks for everything.\n\nRyleigh"
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName(signedByUser, appName: "Claude"), signedByUser)
        XCTAssertEqual(FoundationModelsTransformer.stripLeakedAppName("Hello there.", appName: nil), "Hello there.")
    }

    func testSanitizeStripsTrailingMetaNarration() {
        // Caught LIVE by the gauntlet: correct email first, meta-narration paragraph after.
        let raw = """
        Dear Jessica, please send the email by 3 p.m. Thank you, Ryleigh.

        Here is the rewritten email body according to the provided REWRITE RULE and TRANSCRIPT. The dictation has been formatted into a clear, well-structured email without any added content or sign-off.
        """
        XCTAssertEqual(FoundationModelsTransformer.sanitize(raw),
                       "Dear Jessica, please send the email by 3 p.m. Thank you, Ryleigh.")
    }

    func testSanitizeKeepsRealTrailingParagraphs() {
        // A legit dictation whose last paragraph starts like narration but is NOT about the
        // transformation must survive.
        let real = "First part of the note.\n\nHere is the address for tomorrow: 42 Elm Street."
        XCTAssertEqual(FoundationModelsTransformer.sanitize(real), real)
    }

    func testSanitizeStripsPlaceholderSignatures() {
        // Caught in the field: no username -> literal bracketed placeholder as the signature.
        let raw = "Dear Jessica,\n\nPlease send me that email by 3 p.m.\n\nThank you.\n\n[Speaker\u{2019}s Name]"
        let cleaned = FoundationModelsTransformer.sanitize(raw.replacingOccurrences(of: "\u{2019}", with: "\u{0027}"))
        XCTAssertEqual(cleaned, "Dear Jessica,\n\nPlease send me that email by 3 p.m.\n\nThank you.")
        XCTAssertEqual(FoundationModelsTransformer.sanitize("Body.\n\n[Your Name]"), "Body.")
        XCTAssertEqual(FoundationModelsTransformer.sanitize("Body.\n\n[Signature]"), "Body.")
    }

    func testSanitizeStripsParenthesizedNoNoteTrailer() {
        // Verbatim field output: correct text, then a parenthesized explainer.
        let raw = "I do not see the screen recording menu.\n\n(Note: No changes were made as the transcript was already correct in terms of punctuation and capitalization, and there were no misheard words or hallucinated fragments to correct.)"
        XCTAssertEqual(FoundationModelsTransformer.sanitize(raw),
                       "I do not see the screen recording menu.")
    }

    func testSanitizeKeepsRealParentheticalContent() {
        // A user's own trailing parenthetical must survive: no narration lead, no topic words.
        let real = "Meet me at the garage tomorrow.\n\n(Bring the spare key.)"
        XCTAssertEqual(FoundationModelsTransformer.sanitize(real), real)
    }

    func testStripsRecipientNameSignature() {
        // Tormentor find: with no user name, the model signed with the RECIPIENT from "Dear Marcus".
        let raw = "Dear Marcus,\n\nPlease send the revised numbers by Wednesday.\n\nMarcus"
        XCTAssertEqual(FoundationModelsTransformer.sanitize(raw),
                       "Dear Marcus,\n\nPlease send the revised numbers by Wednesday.")
        // But a legitimate sender signature (different name) survives.
        let ok = "Dear Marcus,\n\nPlease send the revised numbers by Wednesday.\n\nRyleigh"
        XCTAssertEqual(FoundationModelsTransformer.sanitize(ok), ok)
    }

    func testStripsRecipientBracketPlaceholder() {
        XCTAssertEqual(FoundationModelsTransformer.sanitize("Dear [Recipient],\n\nThe meeting ran long.\n\nBest regards,\nRyleigh"),
                       "Dear ,\n\nThe meeting ran long.\n\nBest regards,\nRyleigh")
    }
}
