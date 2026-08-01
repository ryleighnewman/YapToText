import Foundation
import whisper   // the vendored package exposes llama.h alongside whisper.h

/// On-device LLM cleanup via llama.cpp - the reliable alternative to Apple's Foundation
/// model. Loads a GGUF (Qwen2.5 by default), keeps the model cached across calls, and runs
/// a single ChatML completion per transform with greedy decoding for deterministic cleanup.
enum LlamaEngine {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedModel: OpaquePointer?
    nonisolated(unsafe) private static var cachedPath: String?
    nonisolated(unsafe) private static var backendReady = false

    enum LlamaError: LocalizedError {
        case loadFailed, contextFailed, decodeFailed
        var errorDescription: String? {
            switch self {
            case .loadFailed: return "The cleanup model couldn't be loaded. Try re-downloading it on the AI Models page."
            case .contextFailed: return "The cleanup model couldn't start (out of memory?)."
            case .decodeFailed: return "The cleanup model failed while generating."
            }
        }
    }

    private static func sharedModel(path: String) throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        if !backendReady { llama_backend_init(); backendReady = true }
        if let model = cachedModel, cachedPath == path { return model }
        if let ctx = cachedCtx { llama_free(ctx) }   // the context dies with its model
        cachedCtx = nil
        if let old = cachedModel { llama_free_model(old) }
        cachedModel = nil
        cachedPath = nil
        var params = llama_model_default_params()
        params.n_gpu_layers = 99   // Metal
        guard let model = llama_load_model_from_file(path, params) else { throw LlamaError.loadFailed }
        cachedModel = model
        cachedPath = path
        return model
    }

    /// Load the model into memory ahead of first use (fire-and-forget, off the main thread), so
    /// the first AI cleanup after launch doesn't stall for the multi-second GGUF load.
    static func prewarm(modelPath: String) {
        Task.detached(priority: .utility) {
            // Hold inferenceLock across the load: sharedModel frees the previously cached model on a
            // path change, and complete() keeps using that raw pointer for its whole body under
            // inferenceLock. Without this, a prewarm for a different path could free the model a
            // concurrent complete() is still decoding (use-after-free). evictCachedModel serializes
            // the same way. Lock order stays inferenceLock -> lock, so no deadlock; prewarm is
            // fire-and-forget, so blocking here is harmless.
            inferenceLock.lock(); defer { inferenceLock.unlock() }
            _ = try? sharedModel(path: modelPath)
        }
    }

    /// End-of-turn markers used across common instruct templates, as a textual backstop when a
    /// GGUF doesn't flag its stop token as end-of-generation.
    private static let stopMarkers = ["<|im_end|>", "<|end|>", "<|eot_id|>", "<|endoftext|>", "</s>"]

    /// Build the prompt using the model's built-in chat template (nil tmpl = the model's own),
    /// falling back to ChatML if the GGUF carries no template.
    private static func formatChat(model: OpaquePointer, system: String, user: String) -> String {
        func message(_ role: String, _ content: String) -> llama_chat_message {
            llama_chat_message(role: strdup(role), content: strdup(content))
        }
        let msgs = [message("system", system), message("user", user)]
        defer {
            for m in msgs {
                free(UnsafeMutableRawPointer(mutating: m.role))
                free(UnsafeMutableRawPointer(mutating: m.content))
            }
        }
        func apply(_ cap: Int) -> (Int32, [CChar]) {
            var buf = [CChar](repeating: 0, count: cap)
            let n = msgs.withUnsafeBufferPointer { p in
                llama_chat_apply_template(model, nil, p.baseAddress, msgs.count, true, &buf, Int32(cap))
            }
            return (n, buf)
        }
        var cap = (system.utf8.count + user.utf8.count) * 2 + 512
        var (n, buf) = apply(cap)
        if n > Int32(cap) { cap = Int(n) + 16; (n, buf) = apply(cap) }   // buffer too small: grow + retry
        guard n > 0 else {
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Run one instruction + input through the model. Blocking; call from a detached task.
    /// Whether this model is already loaded in the cache (a cold load takes several seconds).
    static func isCached(modelPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedModel != nil && cachedPath == modelPath
    }

    /// Serializes generation AND eviction: the cached model must never be freed mid-decode.
    private static let inferenceLock = NSLock()

    /// The CONTEXT is cached alongside the model. Rebuilding it per cleanup re-allocated
    /// a 1.5GB Metal KV buffer and re-created the whole GPU pipeline on EVERY dictation -
    /// measured as multiple seconds of "processing" before the first generated token.
    /// The KV cache is cleared between runs instead; the context dies with the model.
    nonisolated(unsafe) private static var cachedCtx: OpaquePointer?

    /// Drop the cached model (memory pressure). Waits for any in-flight generation.
    static func evictCachedModel() {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if let ctx = cachedCtx { llama_free(ctx) }
        cachedCtx = nil
        if let model = cachedModel { llama_free_model(model) }
        cachedModel = nil
        cachedPath = nil
    }

    /// Context for the cached model, built once and reused (callers hold inferenceLock).
    private static func sharedContext(model: OpaquePointer) throws -> OpaquePointer {
        if let ctx = cachedCtx { return ctx }
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 1024
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads
        guard let ctx = llama_new_context_with_model(model, ctxParams) else { throw LlamaError.contextFailed }
        cachedCtx = ctx
        return ctx
    }

    static func complete(modelPath: String, system: String, user: String,
                         maxTokens: Int32 = 1024) throws -> String {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        let model = try sharedModel(path: modelPath)

        // Format with the model's OWN chat template (read from the GGUF metadata), so any
        // instruct model - Phi, Llama, ChatML, Gemma, etc. - gets its correct prompt structure
        // and end tokens without hardcoding a template per model.
        let prompt = Self.formatChat(model: model, system: system, user: user)

        let ctx = try sharedContext(model: model)
        // Fresh conversation, reused allocation: clear the KV between runs.
        llama_kv_cache_clear(ctx)

        // Tokenize the prompt.
        let utf8 = Array(prompt.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        let count = utf8.withUnsafeBufferPointer { buf in
            llama_tokenize(model, buf.baseAddress, Int32(buf.count), &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw LlamaError.decodeFailed }
        tokens.removeSubrange(Int(count)...)

        // Prompt too long for the context? Bail to raw text upstream rather than truncating badly.
        guard tokens.count < 3500 else { throw LlamaError.decodeFailed }

        // Decode the prompt in n_batch-sized slices. A single llama_decode asserts (and crashes the
        // process) if its batch exceeds n_batch, and a full system prompt + a long transcript can
        // exceed 1024 tokens. Positions continue automatically from the KV cache across successive
        // llama_batch_get_one calls - exactly how the per-token generation loop below advances - so
        // slicing produces identical results without inflating the compute buffer. (This was a
        // latent crash: any dictation whose prompt topped n_batch would take the app down.)
        // IMPORTANT: llama_batch_get_one only WRAPS the pointer - the decode must happen inside the
        // withUnsafe scope, or it reads a dangling pointer during decode (heap corruption).
        let nBatch = Int(llama_n_batch(ctx))
        var promptOK = true
        var decoded = 0
        while decoded < tokens.count {
            let sliceLen = min(nBatch, tokens.count - decoded)
            let ok = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
                let batch = llama_batch_get_one(buf.baseAddress!.advanced(by: decoded), Int32(sliceLen))
                return llama_decode(ctx, batch) == 0
            }
            if !ok { promptOK = false; break }
            decoded += sliceLen
        }
        guard promptOK else { throw LlamaError.decodeFailed }

        // Greedy sampler: deterministic cleanup, no creative drift.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else { throw LlamaError.decodeFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var out = ""
        var pieceBuf = [CChar](repeating: 0, count: 256)
        var tokenBuf = [llama_token](repeating: 0, count: 1)
        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_token_is_eog(model, token) { break }
            let n = llama_token_to_piece(model, token, &pieceBuf, Int32(pieceBuf.count), 0, true)
            if n > 0 {
                out += String(decoding: pieceBuf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            // Backstop if a model emits its end marker as text instead of an EOG token.
            if let marker = Self.stopMarkers.first(where: { out.hasSuffix($0) }) {
                out.removeLast(marker.count)
                break
            }
            tokenBuf[0] = token
            let stepOK = tokenBuf.withUnsafeMutableBufferPointer { buf -> Bool in
                let batch = llama_batch_get_one(buf.baseAddress, 1)
                return llama_decode(ctx, batch) == 0
            }
            guard stepOK else { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// TextTransformer backed by a downloaded GGUF via llama.cpp. Reuses the same anti-chat
/// guardrail and output sanitizer as the Apple path, so behavior stays consistent.
struct LlamaTransformer: TextTransformer {
    let modelURL: URL

    func transform(_ text: String, mode: Mode, context: TransformContext) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // LONG dictations must be chunked: generation is capped at ~1024 tokens (~4100 chars),
        // and a long transcript's cleanup silently STOPPED at that cap mid-sentence (caught
        // live: 16-minute dictation cut at 4151 chars). Small chunks keep every call far from
        // both the output cap and the 4096-token context.
        if trimmed.count > 2800 {
            var results: [String] = []
            for chunk in FoundationModelsTransformer.chunk(trimmed, maxChars: 2200) {
                results.append(try await transformChunk(chunk, mode: mode, context: TransformContext(), appName: context.appName))
            }
            return results.joined(separator: "\n\n")
        }
        return try await transformChunk(trimmed, mode: mode, context: context, appName: context.appName)
    }

    private func transformChunk(_ text: String, mode: Mode, context: TransformContext, appName: String?) async throws -> String {
        let system = FoundationModelsTransformer.systemPrompt()
        let user = FoundationModelsTransformer.cleanupUserPrompt(for: text, mode: mode, context: context)
        let path = modelURL.path
        let raw = try await Task.detached(priority: .userInitiated) {
            try LlamaEngine.complete(modelPath: path, system: system, user: user, maxTokens: 1400)
        }.value
        return FoundationModelsTransformer.stripLeakedAppName(FoundationModelsTransformer.sanitize(raw), appName: appName)
    }
}
