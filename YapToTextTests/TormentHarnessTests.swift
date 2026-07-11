import XCTest
@testable import YapToText

/// Adversarial logging harness: runs a matrix of inputs/modes/contexts through the bundled
/// Phi GGUF and logs RAW (pre-sanitize) and CLEAN (post-sanitize) output for every case to
/// /tmp/yap-torment.log. No assertions on content - the point is to enumerate contamination
/// shapes the sanitizer does not yet cover. Rerun any time with:
///   xcodebuild ... test-without-building -only-testing:YapToTextTests/TormentHarnessTests
final class TormentHarnessTests: XCTestCase {

    private static var modelURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Models/Phi-3.5-mini-instruct-Q4_K_M.gguf")
    }

    private struct Case {
        let label: String
        let input: String
        let mode: Mode
        let context: TransformContext
    }

    func testTormentMatrix() async throws {
        guard let url = Self.modelURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no bundled model")
        }
        // Sandboxed test host cannot write /tmp; write to the container tmp and copy out after.
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("yap-torment.log").path
        NSLog("TORMENT LOG PATH: %@", logPath)
        FileManager.default.createFile(atPath: logPath, contents: Data())
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            XCTFail("cannot open log at \(logPath)"); return
        }
        defer { try? handle.close() }
        func log(_ s: String) { handle.write((s + "\n").data(using: .utf8)!) }

        // Modes
        var emailGuard = BuiltInModes.email
        emailGuard.instructions += "\n- " + AutoContext.preserveGuard
        let conservative = Mode(name: "AutoRepair", usesAI: true, instructions: AutoContext.conservativeCleanup)
        let modes: [(String, Mode)] = [
            ("clean", BuiltInModes.clean),
            ("email+guard", emailGuard),
            ("conservative", conservative),
            ("note", BuiltInModes.note),
        ]

        // Contexts
        var ctxPoison = TransformContext(); ctxPoison.appName = "Slack"; ctxPoison.userName = nil
        var ctxNamed = TransformContext(); ctxNamed.appName = "Mail"; ctxNamed.userName = "Ryleigh"
        let ctxEmpty = TransformContext()
        let contexts: [(String, TransformContext)] = [
            ("appSlack/noName", ctxPoison),
            ("appMail/Ryleigh", ctxNamed),
            ("empty", ctxEmpty),
        ]

        // Inputs
        let inputs: [(String, String)] = [
            ("casual", "hey are we still on for lunch tomorrow at that taco place"),
            ("letterFull", "Dear Marcus, thanks for meeting with me yesterday. I'll get you the revised numbers by Wednesday. Best, Ryleigh."),
            ("letterNoSignoff", "Dear Marcus, thanks for meeting with me yesterday. I'll get you the revised numbers by Wednesday."),
            ("alreadyPerfect", "The shipment arrives Tuesday and the invoice is already paid."),
            ("wordNote", "quick note to self remember to grab the note from the fridge before leaving"),
            ("colonList", "okay so we need three things: a new charger, two cables, and a case"),
            ("askAssistant", "can you summarize this for me the meeting ran long and we only covered budget"),
            ("mentionsSlack", "I was talking to Slack about the design yesterday and it suggested a darker header"),
            ("rambling150", "so um yeah I was thinking about the whole project timeline thing and honestly I feel like we keep pushing stuff back and back and it's kind of getting out of hand you know like the design phase was supposed to wrap in March and then it slipped to April and now people are saying May and meanwhile the client keeps emailing me asking for updates and I don't really have anything solid to tell them so I think what we should probably do is just lock the scope like actually freeze it no more additions and then work backwards from a hard launch date and if something doesn't fit it goes in version two and also we should probably tell the client that this week not next week because the longer we wait the worse it looks and yeah that's basically where my head is at let me know what you all think"),
            ("spanish", "hola equipo la reunión de mañana se movió a las tres de la tarde gracias"),
            ("ellipsis", "I guess we could try the other vendor but I don't know..."),
            ("spokenNumbers", "call me at five thirty pm the total was two hundred forty seven dollars and the site is example dot com slash pricing"),
        ]

        // ~30 cases x 2 generations (RAW + CLEAN) = ~60 total.
        // clean mode gets all 12 inputs; email 8; conservative 6; note 4. Contexts rotate.
        let counts = [12, 8, 6, 4]
        var cases: [Case] = []
        for (mi, (mName, mode)) in modes.enumerated() {
            for j in 0..<counts[mi] {
                let (iName, input) = inputs[j % inputs.count]
                let (cName, ctx) = contexts[(j + mi) % contexts.count]
                cases.append(Case(label: "\(mName)|\(cName)|\(iName)", input: input, mode: mode, context: ctx))
            }
        }

        let system = FoundationModelsTransformer.systemPrompt()
        let transformer = LlamaTransformer(modelURL: url)
        let path = url.path

        for (idx, c) in cases.enumerated() {
            log("===== CASE \(idx + 1)/\(cases.count) [\(c.label)]")
            log("INPUT=\(c.input)")
            let user = FoundationModelsTransformer.cleanupUserPrompt(for: c.input, mode: c.mode, context: c.context)
            do {
                let raw = try await Task.detached(priority: .userInitiated) {
                    try LlamaEngine.complete(modelPath: path, system: system, user: user)
                }.value
                log("RAW=\(raw)")
            } catch {
                log("RAW=<error: \(error)>")
            }
            do {
                let clean = try await transformer.transform(c.input, mode: c.mode, context: c.context)
                log("CLEAN=\(clean)")
            } catch {
                log("CLEAN=<error: \(error)>")
            }
            log("")
        }
        log("===== DONE \(cases.count) cases")
    }
}
