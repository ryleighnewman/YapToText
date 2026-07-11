import XCTest
@testable import YapToText

/// The live-model gauntlet: real generations on the bundled Phi GGUF, end to end through
/// LlamaTransformer + the sanitizer, asserting the properties users actually depend on.
/// Skips cleanly on a machine without the bundled model.
final class LLMGauntletTests: XCTestCase {

    /// The model INSIDE the test host app bundle - the exact artifact that ships, and the only
    /// location a sandboxed test host is guaranteed to read. (A real-home path silently skipped
    /// every test here: sandbox denied the stat, XCTSkip fired, and the suite looked green.)
    private static var modelURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Models/Phi-3.5-mini-instruct-Q4_K_M.gguf")
    }

    private func transformer() throws -> LlamaTransformer {
        guard let url = Self.modelURL, FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("bundled Phi model missing from the app bundle - the shipping artifact is broken")
            throw XCTSkip("no bundled model")
        }
        return LlamaTransformer(modelURL: url)
    }

    /// Auto mode's conservative repair pass: fixes mishears, PRESERVES the user's voice.
    func testConservativeRepairPreservesVoice() async throws {
        let t = try transformer()
        let mode = Mode(name: "AutoRepair", usesAI: true, instructions: AutoContext.conservativeCleanup)
        let input = "yo dude I'm gonna swing by later tonight after the thing wraps up"
        let out = try await t.transform(input, mode: mode, context: TransformContext())
        let lower = out.lowercased()
        XCTAssertTrue(lower.contains("gonna") || lower.contains("swing by"),
                      "casual voice was rewritten: \(out)")
        XCTAssertLessThan(out.count, input.count * 2, "output ballooned: \(out)")
        XCTAssertFalse(out.contains("\u{2014}"), "em dash introduced: \(out)")
    }

    /// The messy-transcript case: filler removed by Clean Up without inventing content.
    func testCleanupRemovesFillerWithoutInvention() async throws {
        let t = try transformer()
        let mode = BuiltInModes.clean
        let input = "um so hey can you uh send me the the quarterly numbers before friday and also we should probably um schedule a meeting about the new design thing thanks"
        let out = try await t.transform(input, mode: mode, context: TransformContext())
        let lower = out.lowercased()
        XCTAssertFalse(lower.contains(" um "), "filler survived: \(out)")
        XCTAssertTrue(lower.contains("quarterly"), "content lost: \(out)")
        XCTAssertTrue(lower.contains("friday"), "content lost: \(out)")
        XCTAssertLessThan(out.split(separator: " ").count, 60, "over-expanded: \(out)")
    }

    /// The exact bug from the field: Email mode must not echo preambles or sign with the app name.
    func testEmailModeNoPreambleNoAppNameSignature() async throws {
        let t = try transformer()
        var mode = BuiltInModes.email
        mode.instructions += "\n- " + AutoContext.preserveGuard
        let input = "Dear Jessica, how are you today? Please send me that file when you can. Thank you, Ryleigh."
        var context = TransformContext()
        context.appName = "Slack"   // the poison that produced the "Slack" signature
        context.userName = "Ryleigh"
        let out = try await t.transform(input, mode: mode, context: context)
        let lower = out.lowercased()
        XCTAssertFalse(lower.contains("here is"), "preamble leaked: \(out)")
        XCTAssertFalse(lower.contains("rewritten"), "meta-narration leaked: \(out)")
        XCTAssertTrue(lower.contains("jessica"), "recipient lost: \(out)")
        // The app name must never appear as content or signature.
        XCTAssertFalse(out.contains("Slack"), "app name leaked into the email: \(out)")
    }

    /// The one-word classifier the AI tiebreak relies on.
    func testClassifierReturnsEmailForLetter() async throws {
        let t = try transformer()
        let probe = Mode(name: "Classifier", usesAI: true, instructions: AutoContext.aiPrompt)
        let input = "Dear team, I am writing to update you on the launch. Please review the attached plan and let me know your thoughts by Friday. Best regards, Ryleigh"
        let out = try await t.transform(input, mode: probe, context: TransformContext())
        XCTAssertEqual(AutoContext.verdict(fromAI: out), .email, "classifier said: \(out)")
    }

    func testClassifierReturnsMessageForCasual() async throws {
        let t = try transformer()
        let probe = Mode(name: "Classifier", usesAI: true, instructions: AutoContext.aiPrompt)
        let out = try await t.transform("haha yeah dude that was so good, same time next week?",
                                        mode: probe, context: TransformContext())
        XCTAssertEqual(AutoContext.verdict(fromAI: out), .message, "classifier said: \(out)")
    }

    /// Non-English stays non-English (the language guard).
    func testSpanishStaysSpanish() async throws {
        let t = try transformer()
        var mode = BuiltInModes.clean
        mode.instructions += "\n- Write in the same language the user dictated. Do not translate."
        let input = "hola equipo quería avisarles que la reunión de mañana se movió a las tres de la tarde gracias"
        let out = try await t.transform(input, mode: mode, context: TransformContext())
        let lower = out.lowercased()
        XCTAssertTrue(lower.contains("reunión") || lower.contains("reunion") || lower.contains("mañana") || lower.contains("manana"),
                      "translated away from Spanish: \(out)")
    }

    /// THE FIELD CASE: empty username + app-name poison, run 3x because models are stochastic.
    /// This is the exact condition that leaked "Slack" as an email signature in real use.
    func testEmailWithNoUserNameNeverInventsSignature() async throws {
        let t = try transformer()
        var mode = BuiltInModes.email
        mode.instructions += "\n- " + AutoContext.preserveGuard
        var context = TransformContext()
        context.appName = "Slack"
        context.userName = nil          // fresh-install condition: the app does not know the name
        let input = "Dear Jessica, please send the email by 3 p.m. Thank you, Ryleigh."
        for round in 1...3 {
            let out = try await t.transform(input, mode: mode, context: context)
            XCTAssertFalse(out.contains("Slack"), "round \(round): app name leaked: \(out)")
            XCTAssertTrue(out.lowercased().contains("ryleigh"),
                          "round \(round): the user's OWN spoken sign-off was dropped: \(out)")
            XCTAssertFalse(out.lowercased().contains("here is"), "round \(round): preamble: \(out)")
        }
    }

    /// No name available AND none spoken: the email must end clean - no invented name and no
    /// bracketed placeholder. 2 rounds (stochastic).
    func testEmailNoNameAnywhereEndsClean() async throws {
        let t = try transformer()
        var mode = BuiltInModes.email
        mode.instructions += "\n- " + AutoContext.preserveGuard
        var context = TransformContext()
        context.appName = "Slack"
        context.userName = nil
        let input = "Dear Jessica, please send me that email by 3 p.m. Thank you."
        for round in 1...2 {
            let out = try await t.transform(input, mode: mode, context: context)
            XCTAssertFalse(out.contains("["), "round \(round): placeholder bracket: \(out)")
            XCTAssertFalse(out.contains("Slack"), "round \(round): app name: \(out)")
        }
    }
}
