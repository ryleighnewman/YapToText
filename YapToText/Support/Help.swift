import SwiftUI
import AppKit

// MARK: - Help window

/// The in-app manual: real documentation in its own window, fully searchable.
/// Replaces the old interactive Quick Start tour.
@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?
    private init() {}

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HelpView()
            .environment(state)
            .background(AppWindowBackground()))
        let win = NSWindow(contentViewController: hosting)
        win.title = "YapToText Help"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.setContentSize(NSSize(width: 840, height: 620))
        win.minSize = NSSize(width: 700, height: 480)
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Content model

/// One article: a titled page of hand-written blocks.
struct HelpArticle: Identifiable {
    let id: String
    let section: String
    let icon: String
    let title: String
    let summary: String
    let blocks: [HelpBlock]

    /// Plain text of the whole article, for search.
    var searchText: String {
        var parts = [title, summary]
        for block in blocks {
            switch block {
            case .paragraph(let t), .tip(let t), .heading(let t): parts.append(t)
            case .steps(let items): parts.append(contentsOf: items)
            case .keys(let rows): parts.append(contentsOf: rows.map { "\($0.0) \($0.1)" })
            }
        }
        return parts.joined(separator: " ").lowercased()
    }
}

enum HelpBlock {
    case heading(String)
    case paragraph(String)
    case steps([String])
    case keys([(String, String)])   // (shortcut, what it does)
    case tip(String)
}

// MARK: - The manual

enum HelpContent {
    static let articles: [HelpArticle] = [

        HelpArticle(
            id: "first-dictation", section: "Getting started", icon: "mic",
            title: "Your first dictation",
            summary: "Talk, and your words land wherever your cursor is.",
            blocks: [
                .paragraph("Put your cursor anywhere you can type: an email, a note, a chat box. Then start a dictation and just talk. When you stop, YapToText types your words at the cursor, exactly as if you had typed them."),
                .steps([
                    "Click where you want the text to go.",
                    "Tap the Right Command key once. The floating panel appears and the menu bar capybara's bubble turns red.",
                    "Say what you want to write. Watch the live text appear in the panel.",
                    "Tap Right Command again to finish. Your words are typed at the cursor.",
                ]),
                .tip("Nothing happened? The very first launch needs microphone permission. YapToText asks once; after that, dictation starts instantly."),
            ]),

        HelpArticle(
            id: "shortcuts", section: "Getting started", icon: "command",
            title: "Keys and shortcuts",
            summary: "Everything you can press, in one place.",
            blocks: [
                .keys([
                    ("Right \u{2318}", "Start or stop a dictation, from any app"),
                    ("Space", "Pause and resume while dictating"),
                    ("Esc", "Cancel the dictation. Nothing is typed or saved"),
                    ("1 to 9", "Switch the output mode while dictating"),
                ]),
                .paragraph("The Right Command key works two ways, and you pick in Settings. In toggle mode, one tap starts and the next tap stops. In hold mode it becomes a walkie-talkie: recording runs while the key is down and stops the moment you let go."),
                .paragraph("Space and the number keys are only captured while you are actually dictating, so they never interfere with normal typing."),
            ]),

        HelpArticle(
            id: "panel", section: "Getting started", icon: "rectangle.on.rectangle",
            title: "The floating panel",
            summary: "Live text, a real waveform, and transport controls.",
            blocks: [
                .paragraph("While you dictate, a small panel floats above your work. The waveform moves with your actual voice, and the text underneath is the transcription forming in real time."),
                .paragraph("The circular buttons are the same everywhere in the app: pause and resume, stop and insert, and cancel. Drag the panel anywhere; it remembers its place."),
                .tip("Prefer no panel at all? Turn it off in Settings. Dictation still works exactly the same."),
            ]),

        HelpArticle(
            id: "modes", section: "Writing", icon: "slider.horizontal.3",
            title: "Modes",
            summary: "The same words, shaped for where they are going.",
            blocks: [
                .paragraph("A mode decides what happens to your words after they are transcribed. Raw Transcription types exactly what you said, with punctuation, and never touches an AI model. Clean Up removes filler words and false starts and fixes grammar. Note, Email, Message, and Code each reformat your words for that kind of writing."),
                .paragraph("Press a number key from 1 to 9 while dictating to pick the mode for that dictation. The order matches the Modes list, so 1 is always the first mode in your list."),
                .heading("Make it yours"),
                .paragraph("Every mode is editable, including the built-in ones. Open a mode to change its instructions, and the AI will follow them. If a mode almost does what you want, rewrite its instructions until it does. You can also create entirely new modes and give each app its own default mode."),
            ]),

        HelpArticle(
            id: "automode", section: "Writing", icon: "wand.and.sparkles",
            title: "Auto mode",
            summary: "Say it; the app figures out what it is.",
            blocks: [
                .paragraph("With Auto mode on, you stop picking modes. Every dictation is screened in an instant and routed to the right treatment: a letter with a greeting and sign-off becomes a formatted email, casual chat stays exactly as spoken, notes read like notes, and everything else gets the standard cleanup."),
                .paragraph("It reads more than the words. The app you are dictating into counts: Mail leans email, Messages leans casual, editors lean code. If you dictated a name like \u{201C}Dear Jessica\u{201D}, the email is addressed to her. And the output always stays in the language you spoke."),
                .paragraph("Auto never turns your speech into a bulleted list or a headed note on its own - that only happens if you ask for it, either by picking Note mode or by ending a dictation with \u{201C}as a bullet list\u{201D}."),
                .heading("Steer it with your voice"),
                .paragraph("End a dictation with a directive and it becomes an instruction instead of text: \u{201C}\u{2026} make that formal\u{201D}, \u{201C}\u{2026} make it concise\u{201D}, or \u{201C}\u{2026} as a bullet list\u{201D}."),
                .heading("Replying to something?"),
                .paragraph("Select the text you are answering before you start dictating. Auto mode reads the selection (through Accessibility, nothing is copied) and writes your reply to fit what it is responding to."),
                .tip("Turn Auto mode on or off in Settings, in the Home page's quick controls, or during setup. Only genuinely ambiguous dictations consult the AI, so the common cases add no delay."),
            ]),

        HelpArticle(
            id: "cleanup", section: "Writing", icon: "sparkles",
            title: "AI models",
            summary: "The two models that do the work, and how to change them.",
            blocks: [
                .paragraph("Two models run in sequence, and the AI Models page names them exactly that way. The dictation model turns your voice into words: Whisper Large v3 Turbo (Q5) ships inside the app. The cleanup model then turns those words into finished text when the mode asks for it: the bundled Phi-3.5 Mini, or Apple Intelligence if you prefer it."),
                .heading("Choosing a different model"),
                .paragraph("Below your defaults are two libraries: the Dictation Model Library and the Cleanup Model Library. Every entry shows its size and a star rating, and clicking the stars reveals how it rates for accuracy and for performance, plus whether it is the recommended pick. Bigger models hear better; smaller ones are lighter on battery and memory."),
                .paragraph("You can also bring your own. Any whisper.cpp speech model (.bin) or llama.cpp cleanup model (.gguf) can be added under Your own models, and it then appears everywhere a model can be chosen. Anything that is not a supported architecture is rejected automatically."),
                .heading("What runs where"),
                .paragraph("Everything runs on your Mac. Models are stored locally, survive updates, and are never uploaded. Models you download can be removed any time; the bundled ones stay with the app."),
                .tip("The first dictation after launch loads the model, which takes a moment. After that it is fast, and the panel tells you while it happens."),
            ]),

        HelpArticle(
            id: "smartinsert", section: "Writing", icon: "text.cursor",
            title: "Intelligent insert",
            summary: "Dictating into the middle of a sentence, without the cleanup afterwards.",
            blocks: [
                .paragraph("Text dropped into the middle of existing writing usually needs fixing up: a capital letter that should be lowercase, a missing space, a period that closes a sentence which was meant to continue. Intelligent insert does that for you, by reading the words immediately around your cursor before the text lands."),
                .steps([
                    "The first word lowercases itself when you are mid-sentence, sparing names, acronyms, and I.",
                    "Exactly one space is added where words would otherwise collide.",
                    "A trailing period is dropped when the sentence continues after the cursor, or when a period is already sitting there.",
                ]),
                .paragraph("It is on by default and can be switched off in the Home page's quick controls. Apps that do not expose their text simply get the transcript unchanged, and dictating over a selection always replaces that selection rather than adapting to it."),
                .heading("How it reads, and the beep"),
                .paragraph("A sandboxed app is not allowed to read another app's text directly, so YapToText briefly selects a few words on each side of your cursor with synthetic keystrokes, copies them, and puts your clipboard straight back. Nothing is stored and nothing leaves your Mac. If an app never answers, YapToText stops asking it and inserts plainly."),
                .paragraph("Some apps refuse a keystroke they do not expect (a copy with nothing selected, for example) and macOS plays the alert sound for each one. That is the app declining the key, not an error. If it bothers you: open System Settings, choose Sound, and drag the Alert volume slider all the way down. Only alert beeps are silenced; music, video, and dictation sounds are unaffected. You can also switch Intelligent insert off in Quick controls on the Home page."),
            ]),

        HelpArticle(
            id: "dictionaries", section: "Writing", icon: "character.book.closed",
            title: "Dictionaries",
            summary: "Teach the recognizer your names and jargon.",
            blocks: [
                .paragraph("When the microphone keeps hearing a word wrong, put the fix in a dictionary. Each entry says: when you hear this, write that. \u{201C}swift ui\u{201D} becomes SwiftUI, a mumbled brand name becomes the real one, and it applies to every transcript automatically."),
                .steps([
                    "Open Dictionaries and click into the Heard field.",
                    "Type what the recognizer hears, then what it should write instead.",
                    "Click Add. Entries can be edited in place any time, and dragged to reorder.",
                ]),
                .paragraph("Substitutions run top to bottom, and a whole dictionary can be switched off without deleting anything. Multi-word phrases work too."),
            ]),

        HelpArticle(
            id: "commands", section: "Writing", icon: "text.badge.plus",
            title: "Commands",
            summary: "Spoken shortcuts that become symbols and actions.",
            blocks: [
                .paragraph("Commands turn a spoken phrase into something typed. Say \u{201C}insert smiley face\u{201D} and the emoji appears in your text. The insert prefix is there so ordinary sentences that happen to contain a command name never trigger by accident. Multi-word punctuation names like \u{201C}exclamation point\u{201D} and \u{201C}question mark\u{201D} never need it, and the prefix can be switched off entirely on the Commands page."),
                .paragraph("Punctuation commands glue correctly: saying \u{201C}hashtag vibes\u{201D} produces #vibes with no stray space."),
            ]),

        HelpArticle(
            id: "quickedit", section: "Writing", icon: "pencil.and.outline",
            title: "Quick Edit",
            summary: "Select text anywhere, then say the change out loud.",
            blocks: [
                .paragraph("Quick Edit rewrites text that already exists. Select anything in any app, hold the Quick Edit key, and say what you want changed: make this shorter, fix the grammar, turn it into bullet points, translate it to Spanish. The rewrite replaces your selection in place."),
                .steps([
                    "Select the text you want changed.",
                    "Hold the Quick Edit key (Right Option by default) and say the change.",
                    "Release. The selection is replaced with the result.",
                ]),
                .paragraph("It works on anything selectable: an email you are drafting, a comment in your code, a message you have not sent yet. Your instruction is an instruction, not text to insert, so nothing you say is typed literally."),
                .tip("The key and whether it is hold-to-talk or tap-to-toggle are both configurable on the Quick Edit page."),
            ]),

        HelpArticle(
            id: "energy", section: "Around the app", icon: "bolt.badge.clock",
            title: "Energy",
            summary: "This Mac's specifications, and models that follow the power source.",
            blocks: [
                .paragraph("The Energy page shows what this Mac is: its chip, memory, core count, model identifier, and whether it is running on battery or plugged in right now."),
                .heading("Adaptive models"),
                .paragraph("Turn on Switch models with the power source and you can run different models depending on how the Mac is powered. The dictation model and the cleanup model are set separately, each with its own plugged-in and on-battery choice, and every model you have appears in those menus, including ones you added yourself."),
                .paragraph("Leave any of them on Use the main selection to keep whatever is set on the AI Models page. A mode carrying its own model choice always wins over these defaults."),
                .tip("The cleanup model is the heaviest thing the app runs, so putting a lighter one on battery saves the most power."),
            ]),

        HelpArticle(
            id: "menubar", section: "Around the app", icon: "menubar.rectangle",
            title: "The menu bar capybara",
            summary: "Status at a glance, controls one click away.",
            blocks: [
                .paragraph("The capybara in your menu bar always tells the truth: the speech bubble turns red and breathes while recording, becomes a spinner while transcribing, and flashes green when text was inserted. He also blinks. He is alive."),
                .paragraph("Click him for the quick panel: start a dictation, switch mode or microphone, transcribe a file, regenerate your last dictation as any mode, or insert the last dictation again. While recording you get cancel, pause, and stop right in the header."),
                .heading("Regenerate anything"),
                .paragraph("Select text in any app, then open the Regenerate menu to rewrite that selection with any mode. The rewrite replaces the selection in place."),
            ]),

        HelpArticle(
            id: "utility", section: "Around the app", icon: "square.grid.2x2",
            title: "Utility",
            summary: "A workbench for text that is not a live dictation.",
            blocks: [
                .paragraph("Utility is where text jobs happen inside the app. Dictate into the scratchpad instead of another app, paste anything and run it through a mode, or drop an audio or video file to transcribe it. The connectors between the boxes show how text flows from one stage to the next: dictate or paste, transform, then send onward."),
            ]),

        HelpArticle(
            id: "history", section: "Around the app", icon: "clock.arrow.circlepath",
            title: "History and crash rescue",
            summary: "Every dictation kept, searchable, and recoverable.",
            blocks: [
                .paragraph("Every dictation is saved on your Mac: the raw transcript, the final text, which mode ran, and optionally the audio itself. Search it, filter by date or mode, play recordings back, re-copy anything, or regenerate an old dictation with a different mode."),
                .paragraph("Open a dictation's details and it also shows where its time went: how long the dictation model took, how long cleanup took, and how long the text took to reach the app you were in."),
                .heading("If something goes wrong"),
                .paragraph("Recordings are crash-safe. If the app, or your Mac, dies mid-sentence, the audio survives. On the next launch YapToText finds it, transcribes it, puts the text on your clipboard, and files it in History as \u{201C}Recovered after a crash\u{201D}. You do not lose the words."),
            ]),

        HelpArticle(
            id: "stats", section: "Around the app", icon: "chart.bar.xaxis",
            title: "Statistics",
            summary: "What all that talking adds up to.",
            blocks: [
                .paragraph("The Statistics page charts your last 30 days, counts your words and speaking time, works out your real words per minute, and estimates the time saved compared to typing everything at 40 words a minute. Click any bar in the chart to see that day's exact count."),
                .paragraph("Every number is computed on your Mac from your own history, at the moment you open the page. Nothing is tracked, and nothing leaves the machine."),
            ]),

        HelpArticle(
            id: "privacy", section: "Trust", icon: "lock",
            title: "Privacy",
            summary: "On your Mac. Full stop.",
            blocks: [
                .paragraph("Your voice is processed on your Mac. Your transcripts stay on your Mac. There are no accounts, no analytics, and no tracking of any kind. The only network activity is downloading a model when you ask for one."),
                .paragraph("Microphone access is required to hear you. Accessibility permission is required for automatic pasting: macOS only lets apps with that permission type into other apps. Without it, YapToText still transcribes everything and copies the result to your clipboard, and reading selected text for Regenerate is unavailable."),
            ]),

        HelpArticle(
            id: "troubleshooting", section: "Trust", icon: "wrench.adjustable",
            title: "Troubleshooting",
            summary: "The three things that fix almost everything.",
            blocks: [
                .heading("It typed nothing"),
                .paragraph("If the panel said \u{201C}Didn't catch that\u{201D}, the recognizer heard silence. Get closer to the microphone, check the input source in Settings, or raise the input boost if you speak quietly."),
                .heading("Text went to the clipboard instead of the cursor"),
                .paragraph("That happens when the dictation started while YapToText itself was the front window, since the app never types into itself. Click into the app you want first, or just paste: the text is already on your clipboard."),
                .heading("The first dictation is slow"),
                .paragraph("Model loading happens once per launch. The speech model warms up at startup, and the cleanup model loads on its first use. Every dictation after that is quick."),
            ]),
    ]

    static var sections: [String] {
        var seen = [String]()
        for a in articles where !seen.contains(a.section) { seen.append(a.section) }
        return seen
    }
}

// MARK: - View

struct HelpView: View {
    @State private var query = ""
    @State private var selectedID: String? = HelpContent.articles.first?.id

    private var results: [HelpArticle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpContent.articles }
        return HelpContent.articles.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 300)
            article
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }

    // MARK: Topic list

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search help", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            .padding(12)
            .padding(.top, 22)   // clear the transparent titlebar

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if results.isEmpty {
                        Text("No matches. Try a shorter word.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(HelpContent.sections, id: \.self) { section in
                        let items = results.filter { $0.section == section }
                        if !items.isEmpty {
                            Text(section)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 3)
                            ForEach(items) { a in topicRow(a) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func topicRow(_ a: HelpArticle) -> some View {
        Button { selectedID = a.id } label: {
            HStack(spacing: 9) {
                Image(systemName: a.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .iconTint(selectedID == a.id ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(a.title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selectedID == a.id ? Color.secondary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: Article page

    private var article: some View {
        ScrollView {
            if let a = HelpContent.articles.first(where: { $0.id == (results.contains(where: { $0.id == selectedID }) ? selectedID : results.first?.id) }) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: a.icon, tint: .accentColor, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.title2.weight(.semibold))
                            Text(a.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                    ForEach(Array(a.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(28)
                .padding(.top, 20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(a.id)
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .heading(let t):
            Text(t).font(.headline).padding(.top, 6)
        case .paragraph(let t):
            Text(t).font(.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .steps(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.body.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(item).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .innerWell(radius: Metrics.innerRadius)
        case .keys(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(row.1).font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    if i < rows.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .innerWell(radius: Metrics.innerRadius)
        case .tip(let t):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "lightbulb.max").iconTint(Color.accentColor).font(.callout)
                Text(t).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .innerWell(radius: Metrics.innerRadius)
        }
    }
}
