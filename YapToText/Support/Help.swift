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
            case .links(let rows): parts.append(contentsOf: rows.map { "\($0.title) \($0.detail)" })
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
    case links([HelpLink])          // rows that open a page on the web
}

struct HelpLink {
    let icon: String
    let title: String
    let detail: String
    let url: URL
}

// MARK: - The manual

enum HelpContent {
    static let articles: [HelpArticle] = [

        HelpArticle(
            id: "welcome", section: "Getting started", icon: "hand.wave",
            title: "Welcome",
            summary: "Glad you are here.",
            blocks: [
                .paragraph("YapToText turns your voice into text in any app, entirely on your Mac. One key starts it and the same key finishes it. Everything else is optional."),
                .paragraph("It is built by one person, so if something misbehaves, please say:"),
                .links([
                    HelpLink(icon: "ladybug", title: "Direct support",
                             detail: "Open an issue on GitHub. Every one gets read.",
                             url: SupportLinks.issues),
                    HelpLink(icon: "book", title: "The full guide on the web",
                             detail: "Longer walkthroughs and the release notes.",
                             url: SupportLinks.siteHelp),
                    HelpLink(icon: "chevron.left.forwardslash.chevron.right", title: "The source code",
                             detail: "Open source. Nothing leaves your Mac.",
                             url: SupportLinks.repo),
                ]),
            ]),

        HelpArticle(
            id: "first-dictation", section: "Getting started", icon: "mic",
            title: "Your first dictation",
            summary: "Talk, and your words show up wherever your cursor is.",
            blocks: [
                .steps([
                    "Click where you want the text to go.",
                    "Tap Right Command and talk.",
                    "Tap Right Command again. The text lands at your cursor.",
                ]),
                .tip("macOS asks for microphone permission once, on the very first try."),
            ]),

        HelpArticle(
            id: "shortcuts", section: "Getting started", icon: "command",
            title: "Keys and shortcuts",
            summary: "Everything you can press.",
            blocks: [
                .keys([
                    ("Right \u{2318}", "Start or stop a dictation, from any app"),
                    ("Right \u{2325}", "Quick Edit: select text, press, say the change"),
                    ("Space", "Pause and resume while dictating"),
                    ("Esc", "Cancel. Nothing is typed; the words stay in History"),
                    ("1 to 9", "Switch the mode for this dictation"),
                ]),
                .paragraph("Right Command is tap to start and stop by default, or hold to talk if you prefer. Both keys can be remapped on the Home page."),
                .tip("On the Dictation page you can pick a key per app (Return or Command Return) that is pressed for you the moment your words land."),
            ]),

        HelpArticle(
            id: "panel", section: "Getting started", icon: "rectangle.on.rectangle",
            title: "The floating panel",
            summary: "Your voice as a wave, your words as they form.",
            blocks: [
                .paragraph("The round buttons are pause, stop and insert, and cancel. Drag the panel anywhere and it stays there. Size, position, and colors are on the Dictation page, with a live preview."),
                .tip("You can turn the panel off on the Dictation page. Dictation works the same without it."),
            ]),

        HelpArticle(
            id: "modes", section: "Writing", icon: "slider.horizontal.3",
            title: "Modes",
            summary: "The same words, shaped for where they are going.",
            blocks: [
                .paragraph("Raw Transcription types exactly what you said and never touches an AI model. Clean Up drops the ums and false starts and tidies the grammar. Note, Email, Message, and Code shape your words for that kind of writing."),
                .paragraph("Press 1 to 9 while dictating to pick a mode for that one dictation, in the order of your Modes list."),
                .paragraph("Every mode is editable, including the built-in ones. Rewrite its instructions in plain language and the AI follows them. You can also give each app its own default mode."),
            ]),

        HelpArticle(
            id: "automode", section: "Writing", icon: "wand.and.sparkles",
            title: "Auto mode",
            summary: "Say it, and the app works out what it is.",
            blocks: [
                .paragraph("A letter with a greeting and sign-off becomes a formatted email, chat stays as spoken, notes read like notes, and everything else gets the standard cleanup. The app you are dictating into counts too: Mail leans email, Messages leans casual."),
                .paragraph("End a dictation with an instruction and it is followed instead of typed: \u{201C}\u{2026} make that formal\u{201D}, \u{201C}\u{2026} as a bullet list\u{201D}."),
                .paragraph("Replying to something? Select it before you start, and your reply is written to fit."),
            ]),

        HelpArticle(
            id: "cleanup", section: "Writing", icon: "sparkles",
            title: "AI models",
            summary: "Two models, both on your Mac, both swappable.",
            blocks: [
                .paragraph("The dictation model turns your voice into words. The cleanup model turns those words into finished text when a mode asks for it. Both ship inside the app; Apple Intelligence can take the cleanup job if you prefer."),
                .paragraph("The AI Models page has a library for each, with sizes and star ratings. Bigger models hear better, smaller ones are kinder to your battery. Your own whisper.cpp (.bin) and llama.cpp (.gguf) models can be added under Your own models."),
                .tip("The first dictation after launch loads the model, which takes a moment. After that it is quick."),
            ]),

        HelpArticle(
            id: "smartinsert", section: "Writing", icon: "text.cursor",
            title: "Intelligent Insert",
            summary: "Dictate into the middle of a sentence and it fits.",
            blocks: [
                .paragraph("It reads the words around your cursor before the text lands: the first word is lowercased mid-sentence, one space goes where words would collide, and a trailing period is dropped when the sentence carries on. Dictating over a selection replaces it, shaped like the selection."),
                .paragraph("It reads with a few invisible keystrokes, and some apps beep at one of them. Turning Alert volume down in Sound settings silences that. Turn Intelligent Insert off on the Home page, or for one app only on the Dictation page."),
            ]),

        HelpArticle(
            id: "dictionaries", section: "Writing", icon: "character.book.closed",
            title: "Dictionaries",
            summary: "Teach the recognizer your names and jargon.",
            blocks: [
                .paragraph("When a word keeps coming out wrong, add an entry: when you hear this, write that. It applies to every transcript from then on, and a whole dictionary can be switched off without deleting anything."),
                .tip("The fast way: select the correct spelling anywhere, press your Quick Edit key, and say \u{201C}add this to my dictionary\u{201D}."),
            ]),

        HelpArticle(
            id: "commands", section: "Writing", icon: "text.badge.plus",
            title: "Commands",
            summary: "Spoken shortcuts that become symbols.",
            blocks: [
                .paragraph("Say \u{201C}insert smiley face\u{201D} and the emoji appears. The insert prefix keeps ordinary sentences from firing a command by accident; punctuation names like \u{201C}question mark\u{201D} never need it. The prefix can be switched off on the Commands page."),
            ]),

        HelpArticle(
            id: "quickedit", section: "Writing", icon: "pencil.and.outline",
            title: "Quick Edit",
            summary: "Select text anywhere and say what you want changed.",
            blocks: [
                .steps([
                    "Select the text.",
                    "Tap the Quick Edit key (Right Option) and say the change: shorter, fix the grammar, bullet points, Spanish.",
                    "Tap again. The result replaces your selection.",
                ]),
                .paragraph("Exact requests like \u{201C}capitalize this\u{201D} or \u{201C}change this to hearing aids\u{201D} are instant and skip the AI."),
            ]),

        HelpArticle(
            id: "energy", section: "Around the app", icon: "bolt.badge.clock",
            title: "Energy",
            summary: "Models that follow the plug.",
            blocks: [
                .paragraph("Turn on Switch models with the power source and each model gets a plugged-in choice and an on-battery choice. The cleanup model is the heaviest thing the app runs, so a lighter one on battery saves the most."),
            ]),

        HelpArticle(
            id: "menubar", section: "Around the app", icon: "menubar.rectangle",
            title: "The menu bar capybara",
            summary: "Status at a glance, controls one click away.",
            blocks: [
                .paragraph("His speech bubble turns red while recording, spins while transcribing, and flashes green when text was inserted. He also blinks. He is alive."),
                .paragraph("Click him to start a dictation, switch mode or microphone, transcribe a file, regenerate the last dictation as any mode, or insert it again."),
                .tip("Other icon styles are in the Icons card on the Home page."),
            ]),

        HelpArticle(
            id: "utility", section: "Around the app", icon: "square.grid.2x2",
            title: "Utility",
            summary: "A workbench for text that is not a live dictation.",
            blocks: [
                .paragraph("Dictate into the scratchpad, paste anything and run it through a mode, or drop an audio or video file on it to transcribe the whole thing."),
            ]),

        HelpArticle(
            id: "history", section: "Around the app", icon: "clock.arrow.circlepath",
            title: "History and crash rescue",
            summary: "Every dictation kept, searchable, and recoverable.",
            blocks: [
                .paragraph("Every dictation is saved on your Mac with its raw transcript, final text, mode, and optionally the audio. Search it, play it back, copy it again, or regenerate it with a different mode. Cancelled dictations are kept too."),
                .paragraph("If the app or your Mac dies mid-sentence, the audio survives. On the next launch it is transcribed, copied to your clipboard, and filed as \u{201C}Recovered after a crash\u{201D}."),
            ]),

        HelpArticle(
            id: "stats", section: "Around the app", icon: "chart.bar.xaxis",
            title: "Statistics",
            summary: "What all that talking adds up to.",
            blocks: [
                .paragraph("Your last 30 days, your words and speaking time, your real words per minute, and the time saved over typing. Computed on your Mac from your own history, and nothing leaves the machine."),
            ]),

        HelpArticle(
            id: "privacy", section: "Trust", icon: "lock",
            title: "Privacy",
            summary: "On your Mac. Full stop.",
            blocks: [
                .paragraph("Your voice and your transcripts stay on your Mac. No accounts, no analytics, no tracking. The only network use is downloading a model when you ask for one."),
                .paragraph("Microphone access is needed to hear you. Accessibility permission is needed to type into other apps; without it, the text goes to your clipboard instead."),
            ]),

        HelpArticle(
            id: "troubleshooting", section: "Trust", icon: "wrench.adjustable",
            title: "Troubleshooting",
            summary: "The handful of things that fix almost everything.",
            blocks: [
                .heading("It typed nothing"),
                .paragraph("The recognizer heard silence. Get closer to the microphone, check the input on the Dictation page, or raise the input boost."),
                .heading("Text went to the clipboard instead of the cursor"),
                .paragraph("The dictation started while YapToText itself was in front, and the app never types into itself. Click into the app you want first, or just paste."),
                .heading("It hears me badly with a Bluetooth headset or hearing aid"),
                .paragraph("Bluetooth microphones are phone quality. Pick the Mac's own microphone on the Dictation page; the headset keeps its full sound and you still hear everything through it."),
                .heading("The first dictation is slow"),
                .paragraph("Models load once per launch. Every dictation after that is quick."),
                .heading("Something else"),
                .paragraph("Settings, About has a Copy Diagnostics button (Mac model, versions, latency, never your words). Paste it into a GitHub issue; every one gets read."),
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
            Divider()
            Link(destination: SupportLinks.siteHelp) {
                HStack(spacing: 4) {
                    Text("Full guide at yaptotext.com")
                    Image(systemName: "arrow.up.forward").imageScale(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
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
        case .links(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    Link(destination: row.url) {
                        HStack(alignment: .top, spacing: 10) {
                            IconBadge(symbol: row.icon, tint: .accentColor, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
