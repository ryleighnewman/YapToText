import Foundation
import AppKit
import Observation

/// Owns the spoken insert commands (punctuation + emoji) and applies them to a transcript.
/// Runs in the text pipeline so the exact spoken phrase is matched. Matching is whole-phrase and
/// case-insensitive; spacing is fixed only at the insertion site. When `requireInsertPrefix` is
/// on, a command only fires after the word "insert" ("insert period"), so ordinary speech is
/// never replaced by accident.
@Observable
final class CommandStore {
    private(set) var commands: [SpokenCommand]
    var isEnabled: Bool { didSet { save() } }
    var requireInsertPrefix: Bool { didSet { save() } }

    @ObservationIgnored private static let fileName = "commands.json"
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    struct Snapshot: Codable {
        var isEnabled: Bool
        var requireInsertPrefix: Bool?
        var commands: [SpokenCommand]
    }

    init() {
        if let snap = Persistence.load(Snapshot.self, from: CommandStore.fileName) {
            isEnabled = snap.isEnabled
            requireInsertPrefix = snap.requireInsertPrefix ?? true
            commands = snap.commands
        } else {
            isEnabled = true
            requireInsertPrefix = true
            commands = CommandStore.defaults
        }
    }

    func commands(in category: CommandCategory) -> [SpokenCommand] {
        commands.filter { $0.category == category }
    }

    // MARK: Apply

    func apply(to text: String) -> String {
        guard isEnabled else { return text }
        // Apply longer trigger phrases first so "exclamation point" wins before "exclamation"
        // can match the word inside it, regardless of authoring order.
        let pairs = commands
            .filter(\.enabled)
            .flatMap { command in
                command.triggers
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { (trigger: $0, output: command.output) }
            }
            .sorted { $0.trigger.count > $1.trigger.count }
        var result = text
        for pair in pairs {
            result = CommandStore.replace(trigger: pair.trigger, with: CommandStore.expandTokens(pair.output),
                                          requirePrefix: requireInsertPrefix, in: result)
        }
        return result
    }

    /// Live tokens usable in any command's output, expanded at dictation time:
    /// {date}, {time}, and {clipboard}.
    static func expandTokens(_ output: String) -> String {
        guard output.contains("{") else { return output }
        var s = output
        if s.contains("{date}") {
            s = s.replacingOccurrences(of: "{date}",
                                       with: Date().formatted(date: .abbreviated, time: .omitted))
        }
        if s.contains("{time}") {
            s = s.replacingOccurrences(of: "{time}",
                                       with: Date().formatted(date: .omitted, time: .shortened))
        }
        if s.contains("{clipboard}") {
            s = s.replacingOccurrences(of: "{clipboard}",
                                       with: NSPasteboard.general.string(forType: .string) ?? "")
        }
        return s
    }

    /// Replace a whole-phrase, case-insensitive trigger. Multi-word triggers tolerate any run of
    /// whitespace between words. Spacing is fixed only at the insertion site - attaching
    /// punctuation swallows the space before it, a line break swallows spaces on both sides - so
    /// punctuation the user dictated elsewhere is never touched. With `requirePrefix`, the word
    /// "insert" must appear immediately before the trigger.
    /// Compiled-regex cache. The pattern string fully determines the regex (options are always
    /// `.caseInsensitive`), so a cached entry is always valid for its key and never needs
    /// invalidation - a changed trigger or setting produces a different pattern, hence a different
    /// key. Removes ~300 ICU compiles from the main-actor insert path on every dictation.
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()
    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock(); defer { regexCacheLock.unlock() }
        if let hit = regexCache[pattern] { return hit }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        regexCache[pattern] = compiled
        return compiled
    }

    static func replace(trigger: String, with output: String, requirePrefix: Bool, in text: String) -> String {
        let words = trigger.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return text }
        let phrase = words.joined(separator: "\\s+")
        let lead = (trigger.first?.isLetter ?? false) || (trigger.first?.isNumber ?? false) ? "\\b" : ""
        let trail = (trigger.last?.isLetter ?? false) || (trigger.last?.isNumber ?? false) ? "\\b" : ""
        let isNewline = !output.isEmpty && output.allSatisfy { $0 == "\n" }
        let attaches = output.first.map { ".,!?;:".contains($0) } ?? false
        // Outputs that END in a joining symbol (hashtag, at-sign, openers) glue to the NEXT word:
        // "hashtag vibes" becomes "#vibes", not "# vibes". Mirrors the leading-attach rule above.
        let attachesNext = output.last.map { "#@([{$\u{201C}\u{2018}".contains($0) } ?? false
        let eatLead = (attaches || isNewline) ? "[ \\t]*" : ""
        let eatTrail = (isNewline || attachesNext) ? "[ \\t]*" : ""
        let prefix = requirePrefix ? "\\binsert\\s+" : ""
        let pattern = eatLead + prefix + lead + phrase + trail + eatTrail
        guard let regex = cachedRegex(pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: output)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // MARK: Mutations

    @discardableResult
    func add(category: CommandCategory) -> SpokenCommand {
        let command = SpokenCommand(triggers: [], output: "", category: category)
        commands.append(command)
        save()
        return command
    }

    func update(_ command: SpokenCommand) {
        guard let i = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[i] = command
        save()
    }

    func delete(_ command: SpokenCommand) {
        commands.removeAll { $0.id == command.id }
        save()
    }

    func setEnabled(_ command: SpokenCommand, _ enabled: Bool) {
        guard let i = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[i].enabled = enabled
        save()
    }

    /// Replace the whole command set from an imported snapshot (Export All / Import).
    func replaceAll(with snapshot: Snapshot) {
        isEnabled = snapshot.isEnabled
        requireInsertPrefix = snapshot.requireInsertPrefix ?? requireInsertPrefix
        commands = snapshot.commands
        flush()
    }

    func restoreDefaults(for category: CommandCategory) {
        commands.removeAll { $0.category == category }
        commands.append(contentsOf: CommandStore.defaults.filter { $0.category == category })
        save()
    }

    // MARK: Persistence (debounced)

    private func save() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        Persistence.save(Snapshot(isEnabled: isEnabled, requireInsertPrefix: requireInsertPrefix, commands: commands),
                         to: CommandStore.fileName)
    }

    // MARK: Defaults

    static let defaults: [SpokenCommand] = punctuationDefaults + emojiDefaults + snippetDefaults

    private static let snippetDefaults: [SpokenCommand] = [
        SpokenCommand(triggers: ["today's date", "todays date"], output: "{date}", category: .snippet),
        SpokenCommand(triggers: ["current time", "the time right now"], output: "{time}", category: .snippet),
        SpokenCommand(triggers: ["paste my clipboard", "insert my clipboard"], output: "{clipboard}", category: .snippet),
        SpokenCommand(triggers: ["shrug face"], output: #"¯\_(ツ)_/¯"#, category: .snippet),
        SpokenCommand(triggers: ["my email signature"], output: "Best,\n", category: .snippet),
    ]

    private static func p(_ output: String, _ triggers: [String]) -> SpokenCommand {
        SpokenCommand(triggers: triggers, output: output, category: .punctuation)
    }
    private static func e(_ output: String, _ triggers: [String]) -> SpokenCommand {
        SpokenCommand(triggers: triggers, output: output, category: .emoji)
    }

    private static let punctuationDefaults: [SpokenCommand] = [
        p(".", ["period", "full stop"]),
        p(",", ["comma"]),
        p("?", ["question mark"]),
        p("!", ["exclamation point", "exclamation mark", "exclamation", "bang"]),
        p(":", ["colon"]),
        p(";", ["semicolon", "semi colon"]),
        p("-", ["hyphen", "dash", "minus sign"]),
        p("…", ["ellipsis", "dot dot dot"]),
        p("(", ["open paren", "open parenthesis", "left paren"]),
        p(")", ["close paren", "close parenthesis", "right paren"]),
        p("[", ["open bracket", "left bracket", "open square bracket"]),
        p("]", ["close bracket", "right bracket", "close square bracket"]),
        p("{", ["open brace", "left brace", "open curly brace"]),
        p("}", ["close brace", "right brace", "close curly brace"]),
        p("\"", ["quote", "double quote", "quotation mark"]),
        p("'", ["apostrophe", "single quote"]),
        p("/", ["slash", "forward slash"]),
        p("\\", ["backslash", "back slash"]),
        p("&", ["ampersand"]),
        p("@", ["at sign", "at symbol"]),
        p("#", ["hashtag", "hash sign", "pound sign", "number sign"]),
        p("%", ["percent sign", "percent symbol"]),
        p("*", ["asterisk", "star symbol"]),
        p("+", ["plus sign"]),
        p("=", ["equals sign", "equal sign"]),
        p("$", ["dollar sign"]),
        p("€", ["euro sign"]),
        p("£", ["pound sign symbol", "sterling sign"]),
        p("¢", ["cent sign"]),
        p("•", ["bullet point", "bullet symbol"]),
        p("°", ["degree sign", "degrees symbol"]),
        p("^", ["caret symbol"]),
        p("~", ["tilde"]),
        p("_", ["underscore"]),
        p("|", ["vertical bar", "pipe symbol"]),
        p("<", ["less than sign", "left angle bracket"]),
        p(">", ["greater than sign", "right angle bracket"]),
        p("©", ["copyright sign", "copyright symbol"]),
        p("®", ["registered sign", "registered trademark"]),
        p("™", ["trademark sign", "trademark symbol"]),
        p("§", ["section sign"]),
        p("¶", ["paragraph sign", "pilcrow"]),
        p("\t", ["tab key"]),
        p("\n", ["new line", "line break"]),
        p("\n\n", ["new paragraph"]),
    ]

    private static let emojiDefaults: [SpokenCommand] = [
        // Faces
        e("😀", ["grinning emoji", "grinning face"]),
        e("😃", ["smiling emoji"]),
        e("😄", ["happy emoji", "happy face"]),
        e("😁", ["grin emoji", "big smile emoji"]),
        e("😊", ["smiley face", "smiley emoji", "smile emoji"]),
        e("🙂", ["slight smile emoji"]),
        e("😂", ["laughing emoji", "crying laughing emoji", "tears of joy emoji"]),
        e("🤣", ["rofl emoji", "rolling laughing emoji"]),
        e("🙃", ["upside down emoji"]),
        e("😉", ["wink emoji", "winking emoji"]),
        e("😍", ["heart eyes emoji", "love eyes emoji"]),
        e("🥰", ["smiling hearts emoji", "adoring emoji"]),
        e("😘", ["kiss emoji", "blowing kiss emoji"]),
        e("😋", ["yum emoji", "delicious emoji"]),
        e("😜", ["tongue out emoji", "playful emoji"]),
        e("🤪", ["crazy face emoji", "goofy emoji"]),
        e("😎", ["sunglasses emoji", "cool emoji"]),
        e("🤓", ["nerd emoji", "nerd face"]),
        e("🤔", ["thinking emoji", "thinking face"]),
        e("😐", ["neutral face emoji", "straight face emoji"]),
        e("🙄", ["eye roll emoji", "rolling eyes emoji"]),
        e("😏", ["smirk emoji", "smirking emoji"]),
        e("😴", ["sleeping emoji", "sleepy emoji"]),
        e("😌", ["relieved emoji"]),
        e("😔", ["sad face emoji", "pensive emoji"]),
        e("😢", ["crying emoji", "cry emoji", "single tear emoji"]),
        e("😭", ["sobbing emoji", "bawling emoji", "loud crying emoji"]),
        e("😤", ["frustrated emoji", "steam emoji"]),
        e("😠", ["angry emoji", "mad emoji"]),
        e("😡", ["rage emoji", "furious emoji"]),
        e("🤬", ["cursing emoji", "swearing emoji"]),
        e("🤯", ["mind blown emoji", "exploding head emoji"]),
        e("😳", ["flushed emoji", "embarrassed emoji"]),
        e("🥺", ["pleading emoji", "puppy eyes emoji"]),
        e("😱", ["screaming emoji", "shocked emoji"]),
        e("😨", ["scared emoji", "fearful emoji"]),
        e("😅", ["nervous laugh emoji", "sweat smile emoji"]),
        e("🤫", ["shushing emoji", "quiet emoji"]),
        e("🤐", ["zipper mouth emoji", "lips sealed emoji"]),
        e("🤢", ["nauseous emoji", "sick emoji"]),
        e("🤮", ["vomiting emoji", "throwing up emoji"]),
        e("😷", ["mask emoji", "face mask emoji"]),
        e("🤑", ["money face emoji", "money mouth emoji"]),
        e("🤠", ["cowboy emoji"]),
        e("🥳", ["party face emoji", "celebrating emoji"]),
        e("🤡", ["clown emoji"]),
        e("👻", ["ghost emoji"]),
        e("💀", ["skull emoji", "dead emoji"]),
        e("👽", ["alien emoji"]),
        e("🤖", ["robot emoji"]),
        e("💩", ["poop emoji"]),
        e("🎃", ["pumpkin emoji", "jack o lantern emoji"]),
        // Gestures + body
        e("👍", ["thumbs up emoji", "thumbs up"]),
        e("👎", ["thumbs down emoji", "thumbs down"]),
        e("👌", ["ok hand emoji", "okay emoji"]),
        e("👏", ["clapping emoji", "clap emoji"]),
        e("🙌", ["raised hands emoji", "praise emoji"]),
        e("👋", ["wave emoji", "waving emoji"]),
        e("🙏", ["pray emoji", "praying emoji", "thank you emoji", "folded hands emoji"]),
        e("💪", ["muscle emoji", "flex emoji"]),
        e("👉", ["pointing right emoji"]),
        e("👈", ["pointing left emoji"]),
        e("👆", ["pointing up emoji"]),
        e("👇", ["pointing down emoji"]),
        e("👊", ["fist bump emoji", "fist emoji"]),
        e("✊", ["raised fist emoji"]),
        e("✌️", ["peace emoji", "victory emoji"]),
        e("🤞", ["crossed fingers emoji", "fingers crossed emoji"]),
        e("🤟", ["love you hand emoji", "rock on emoji"]),
        e("🤙", ["call me emoji", "shaka emoji"]),
        e("🤝", ["handshake emoji"]),
        e("✍️", ["writing hand emoji"]),
        e("👀", ["eyes emoji", "looking emoji"]),
        e("🧠", ["brain emoji"]),
        // Hearts + symbols
        e("❤️", ["heart emoji", "red heart emoji", "love emoji"]),
        e("🧡", ["orange heart emoji"]),
        e("💛", ["yellow heart emoji"]),
        e("💚", ["green heart emoji"]),
        e("💙", ["blue heart emoji"]),
        e("💜", ["purple heart emoji"]),
        e("🖤", ["black heart emoji"]),
        e("🤍", ["white heart emoji"]),
        e("💔", ["broken heart emoji"]),
        e("💖", ["sparkling heart emoji"]),
        e("💕", ["two hearts emoji"]),
        e("💯", ["hundred emoji", "one hundred emoji", "keep it a hundred emoji"]),
        e("🔥", ["fire emoji", "flame emoji", "lit emoji"]),
        e("⭐️", ["star emoji"]),
        e("🌟", ["glowing star emoji", "shining star emoji"]),
        e("✨", ["sparkles emoji", "sparkle emoji"]),
        e("💥", ["boom emoji", "explosion emoji"]),
        e("⚡️", ["lightning emoji", "zap emoji"]),
        e("✅", ["check mark emoji", "green check emoji"]),
        e("✔️", ["heavy check emoji", "checkmark emoji"]),
        e("❌", ["cross mark emoji", "x mark emoji", "red x emoji"]),
        e("⚠️", ["warning emoji", "caution emoji"]),
        // Celebration + objects
        e("🎉", ["party emoji", "tada emoji", "celebration emoji"]),
        e("🎊", ["confetti emoji", "party popper emoji"]),
        e("🎈", ["balloon emoji"]),
        e("🎁", ["gift emoji", "present emoji"]),
        e("🎂", ["birthday cake emoji"]),
        e("🚀", ["rocket emoji"]),
        e("🏆", ["trophy emoji"]),
        e("🥇", ["gold medal emoji", "first place emoji"]),
        e("👑", ["crown emoji"]),
        e("💎", ["diamond emoji", "gem emoji"]),
        e("💰", ["money bag emoji", "money emoji"]),
        e("💸", ["money wings emoji", "cash emoji"]),
        e("💡", ["light bulb emoji", "idea emoji"]),
        e("🔑", ["key emoji"]),
        e("🔒", ["lock emoji"]),
        e("🔔", ["bell emoji"]),
        e("📌", ["pushpin emoji", "pin emoji"]),
        e("📎", ["paperclip emoji"]),
        e("✂️", ["scissors emoji"]),
        e("📝", ["memo emoji", "note emoji"]),
        e("📚", ["books emoji"]),
        e("✏️", ["pencil emoji"]),
        e("📱", ["phone emoji", "smartphone emoji"]),
        e("💻", ["laptop emoji", "computer emoji"]),
        e("✉️", ["envelope emoji", "email emoji"]),
        e("📷", ["camera emoji"]),
        e("🎵", ["music note emoji", "music emoji"]),
        e("🎤", ["microphone emoji", "mic emoji"]),
        e("🎧", ["headphones emoji"]),
        e("🎮", ["video game emoji", "controller emoji"]),
        e("⚽️", ["soccer ball emoji", "football emoji"]),
        e("🏀", ["basketball emoji"]),
        // Nature + food + animals
        e("☀️", ["sun emoji", "sunny emoji"]),
        e("🌙", ["moon emoji"]),
        e("☁️", ["cloud emoji"]),
        e("🌈", ["rainbow emoji"]),
        e("❄️", ["snowflake emoji", "snow emoji"]),
        e("🌊", ["wave water emoji", "ocean emoji"]),
        e("🌳", ["tree emoji"]),
        e("🌸", ["blossom emoji", "cherry blossom emoji"]),
        e("🌹", ["rose emoji"]),
        e("🍀", ["four leaf clover emoji", "lucky clover emoji"]),
        e("🐶", ["dog emoji", "puppy emoji"]),
        e("🐱", ["cat emoji"]),
        e("🦄", ["unicorn emoji"]),
        e("🐝", ["bee emoji"]),
        e("🦋", ["butterfly emoji"]),
        e("🍕", ["pizza emoji"]),
        e("🍔", ["burger emoji", "hamburger emoji"]),
        e("🍟", ["fries emoji"]),
        e("🌮", ["taco emoji"]),
        e("☕️", ["coffee emoji"]),
        e("🍺", ["beer emoji"]),
        e("🍷", ["wine emoji"]),
        e("🥂", ["cheers emoji", "clinking glasses emoji"]),
        e("🍎", ["apple emoji"]),
        e("🍌", ["banana emoji"]),
        e("🥑", ["avocado emoji"]),
        e("🍩", ["donut emoji", "doughnut emoji"]),
        e("🍪", ["cookie emoji"]),
        e("🍦", ["ice cream emoji"]),
        e("🍿", ["popcorn emoji"]),
    ]
}
