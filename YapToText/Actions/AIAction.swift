import Foundation

/// A one-shot AI transformation you run on whatever text is selected in any app: "Improve
/// Writing", "Fix Grammar", "Summarize", etc. Like a mode, but it acts on your current
/// selection instead of on dictation, and replaces it in place.
struct AIAction: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var iconSystemName: String
    var instructions: String
    var isBuiltIn: Bool = false
}
