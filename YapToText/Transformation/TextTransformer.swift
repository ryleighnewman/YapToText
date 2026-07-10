import Foundation

/// Context blocks that an AI mode can inject alongside the transcript.
struct TransformContext: Sendable {
    var appName: String?
    var selectedText: String?
    var clipboard: String?
    /// The speaker's own name, so AI modes can sign off with it instead of a "[Your Name]" placeholder.
    var userName: String?
}

/// Applies a mode's optional AI transformation to a raw transcript.
protocol TextTransformer: Sendable {
    func transform(_ text: String, mode: Mode, context: TransformContext) async throws -> String
}

/// Used for raw modes and whenever AI is unavailable: returns the text unchanged.
struct PassthroughTransformer: TextTransformer {
    func transform(_ text: String, mode: Mode, context: TransformContext) async throws -> String { text }
}
