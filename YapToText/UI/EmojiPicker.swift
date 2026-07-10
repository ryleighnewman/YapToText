import SwiftUI

/// The full system emoji set, generated from Unicode scalar ranges and searchable by each
/// emoji's official Unicode name - so "every single emoji" is available without hand-curating
/// a list. Grouped into familiar categories by code block.
enum EmojiCatalog {
    struct Entry: Identifiable, Hashable {
        var id: String { emoji }
        let emoji: String
        let name: String
    }

    struct Category: Identifiable {
        var id: String { name }
        let name: String
        let entries: [Entry]
    }

    /// Ranges chosen to cover the emoji blocks; scalars are filtered to ones macOS can
    /// actually render as emoji.
    private static let blocks: [(String, [ClosedRange<UInt32>])] = [
        ("Smileys & Emotion", [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9D0]),
        ("People & Body", [0x1F440...0x1F450, 0x1F464...0x1F483, 0x1F9B0...0x1F9B9, 0x1F930...0x1F93E]),
        ("Animals & Nature", [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344]),
        ("Food & Drink", [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F32D...0x1F32F]),
        ("Activities", [0x1F380...0x1F3C4, 0x1F3C5...0x1F3D3, 0x26BD...0x26BE, 0x1F94A...0x1F94F]),
        ("Travel & Places", [0x1F680...0x1F6FF, 0x1F30D...0x1F320, 0x1F3D4...0x1F3FA]),
        ("Objects", [0x1F4A0...0x1F4FF, 0x1F500...0x1F53D, 0x1F9E0...0x1F9FF, 0x231A...0x231B]),
        ("Symbols", [0x2600...0x26FF, 0x2700...0x27BF, 0x1F300...0x1F30C, 0x2B00...0x2BFF, 0x1F191...0x1F19A]),
        ("Flags", [0x1F1E6...0x1F1FF]),
    ]

    static let categories: [Category] = {
        var seen = Set<String>()
        var result: [Category] = []
        for (name, ranges) in blocks {
            var entries: [Entry] = []
            for range in ranges {
                for value in range {
                    guard let scalar = Unicode.Scalar(value),
                          scalar.properties.isEmoji,
                          scalar.properties.isEmojiPresentation || value >= 0x1F000 else { continue }
                    let emoji = String(scalar)
                    guard seen.insert(emoji).inserted else { continue }
                    entries.append(Entry(emoji: emoji, name: scalar.properties.name?.capitalized ?? ""))
                }
            }
            if !entries.isEmpty { result.append(Category(name: name, entries: entries)) }
        }
        return result
    }()

    static func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return categories.flatMap(\.entries).filter { $0.name.lowercased().contains(q) }
    }
}

/// Searchable grid of every emoji; tapping one hands it back and closes the popover.
struct EmojiPickerView: View {
    let onPick: (String) -> Void
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 4), count: 1)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji (e.g. fire, heart, cat)", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            ScrollView {
                if query.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                        ForEach(EmojiCatalog.categories) { category in
                            Text(category.name)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 4)
                            grid(category.entries)
                        }
                    }
                } else {
                    let hits = EmojiCatalog.search(query)
                    if hits.isEmpty {
                        Text("No emoji named \u{201C}\(query)\u{201D}.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                    } else {
                        grid(hits)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 320, height: 360)
    }

    private func grid(_ entries: [EmojiCatalog.Entry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 4)], spacing: 4) {
            ForEach(entries) { entry in
                Button { onPick(entry.emoji) } label: {
                    Text(entry.emoji).font(.system(size: 22))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
            }
        }
    }
}
