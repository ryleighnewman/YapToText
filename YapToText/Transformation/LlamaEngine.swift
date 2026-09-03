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
        cachedPromptTokens = []
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

    /// FULL warm for launch: not just the weights (that is `prewarm`), but the flash-attn
    /// context, the compiled Metal kernels, AND the fixed system-prompt prefix left resident in
    /// the KV cache. Cleanup is the biggest cold cost on the first dictation (~1.4s of context
    /// build + shader compile + guardrail prefill); after this it runs at warm speed (~0.2s)
    /// from the very first use. Runs one throwaway completion (1 token) with the real guardrail
    /// so the prefix cache is seeded exactly the way the first real cleanup will want it.
    static func fullWarm(modelPath: String) {
        Task.detached(priority: .utility) {
            _ = try? complete(modelPath: modelPath,
                              system: FoundationModelsTransformer.systemPrompt(),
                              user: "Warm up.", maxTokens: 1)
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
    /// The prompt tokens currently resident in cachedCtx's KV cache (positions 0..<count).
    /// Lets the next call re-encode only the tokens that differ from this prefix. MUST be
    /// reset to [] whenever the context is torn down or rebuilt, or the KV and this record
    /// fall out of sync and reuse decodes at the wrong positions.
    nonisolated(unsafe) private static var cachedPromptTokens: [llama_token] = []

    /// Drop the cached model (memory pressure). Waits for any in-flight generation.
    static func evictCachedModel() {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if let ctx = cachedCtx { llama_free(ctx) }
        cachedCtx = nil
        cachedPromptTokens = []
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
        // Flash attention on Metal: same math, fused kernel - faster prompt prefill and
        // decode with NO change to the output. Whisper already runs with it; the cleanup
        // LLM (the measured bottleneck, ~1.4s vs ~0.3s for transcription) did not. Keeps
        // Phi's quality identical while cutting its latency.
        ctxParams.flash_attn = true
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads
        guard let ctx = llama_new_context_with_model(model, ctxParams) else { throw LlamaError.contextFailed }
        cachedCtx = ctx
        cachedPromptTokens = []   // fresh, empty KV
        return ctx
    }

    static func complete(modelPath: String, system: String, user: String,
                         draft: String? = nil, maxTokens: Int32 = 1024) throws -> String {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        let model = try sharedModel(path: modelPath)

        // Format with the model's OWN chat template (read from the GGUF metadata), so any
        // instruct model - Phi, Llama, ChatML, Gemma, etc. - gets its correct prompt structure
        // and end tokens without hardcoding a template per model.
        let prompt = Self.formatChat(model: model, system: system, user: user)

        let ctx = try sharedContext(model: model)

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

        // PROMPT-PREFIX KV REUSE (the big speed win): the cleanup prompt is ~1100 tokens, but
        // nearly all of it - the safety guardrail plus the fixed REWRITE-RULE framing - is
        // IDENTICAL on every dictation; only the ~30-token transcript at the tail changes.
        // Re-encoding the whole prompt cost ~1s of prefill per dictation (measured), dwarfing
        // the ~0.15s of actual generation. So we keep the previous call's KV cache and re-encode
        // only the tokens that differ: find how long a prefix this prompt shares with the last
        // one, drop the KV from that point on (which also clears the previous run's generated
        // tail), and decode just the divergent remainder. Reusing a prefix's KV yields the same
        // logits as recomputing it - positions and attention are identical - so the output is
        // unchanged; only the redundant compute is skipped.
        let nBatch = Int(llama_n_batch(ctx))
        var reuse = 0
        let maxReuse = min(cachedPromptTokens.count, tokens.count - 1)   // keep >=1 token to decode for fresh logits
        while reuse < maxReuse && cachedPromptTokens[reuse] == tokens[reuse] { reuse += 1 }
        if reuse > 0 {
            // Evict positions >= reuse for sequence 0; the KV now holds exactly the shared prefix,
            // and the next decode continues at position `reuse` (llama tracks n_past from the cache).
            llama_kv_cache_seq_rm(ctx, 0, Int32(reuse), -1)
        } else {
            llama_kv_cache_clear(ctx)
        }
        // Until this call finishes cleanly, the KV/record could disagree - clear the record so a
        // failure can never leave a stale prefix that a later call would trust.
        cachedPromptTokens = []

        // Decode the divergent tail in n_batch-sized slices. A single llama_decode asserts (and
        // crashes the process) if its batch exceeds n_batch. Positions continue automatically from
        // the KV cache across successive llama_batch_get_one calls - exactly how the per-token
        // generation loop below advances - so slicing (and the prefix reuse above) produce
        // identical results without inflating the compute buffer.
        // IMPORTANT: llama_batch_get_one only WRAPS the pointer - the decode must happen inside the
        // withUnsafe scope, or it reads a dangling pointer during decode (heap corruption).
        var promptOK = true
        var decoded = reuse
        while decoded < tokens.count {
            let sliceLen = min(nBatch, tokens.count - decoded)
            let ok = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
                let batch = llama_batch_get_one(buf.baseAddress!.advanced(by: decoded), Int32(sliceLen))
                return llama_decode(ctx, batch) == 0
            }
            if !ok { promptOK = false; break }
            decoded += sliceLen
        }
        guard promptOK else { llama_kv_cache_clear(ctx); throw LlamaError.decodeFailed }
        // The KV now holds exactly these prompt tokens at positions 0..<count; record it so the
        // NEXT call can reuse this prefix. (Generation appends tokens beyond this, but the next
        // call's seq_rm drops everything past the shared prefix, generated tail included.)
        cachedPromptTokens = tokens

        // Greedy sampler: deterministic cleanup, no creative drift.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else { throw LlamaError.decodeFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        // SELF-SPECULATIVE DECODING: cleanup is copy-editing, so the model mostly re-types
        // the raw transcript. Use the transcript itself as the draft: after each confirmed
        // token, look up where the draft continues the same way and decode a RUN of draft
        // tokens in one batch, verifying every position against the model's own greedy
        // argmax. Sampling is greedy, so accepted runs are bit-identical to what the plain
        // loop would have produced - this changes speed, never output. Where the model
        // edits (the interesting parts), verification fails and decoding falls back to
        // single steps until the draft realigns.
        var draftTokens: [llama_token] = []
        if let draft, !draft.isEmpty {
            let dUtf8 = Array(draft.utf8)
            var dBuf = [llama_token](repeating: 0, count: dUtf8.count + 8)
            let dn = llama_tokenize(model, draft, Int32(dUtf8.count), &dBuf, Int32(dBuf.count), false, false)
            if dn > 0 { draftTokens = Array(dBuf[0..<Int(dn)]) }
        }
        let specWidth = 10
        let nVocab = Int(llama_n_vocab(model))

        func argmax(_ i: Int32) -> llama_token {
            guard let logits = llama_get_logits_ith(ctx, i) else { return -1 }
            var best = 0
            var bestV = logits[0]
            for v in 1..<nVocab where logits[v] > bestV { best = v; bestV = logits[v] }
            return llama_token(best)
        }
        /// Next draft run after a (prev, cur) pair - bigram match first, unigram fallback.
        func speculate(prev: llama_token?, cur: llama_token) -> [llama_token] {
            guard draftTokens.count > 1 else { return [] }
            var fallback: Int? = nil
            for i in 0..<(draftTokens.count - 1) where draftTokens[i] == cur {
                if let prev, i > 0, draftTokens[i - 1] != prev {
                    if fallback == nil { fallback = i }
                    continue
                }
                return Array(draftTokens[(i + 1)..<min(draftTokens.count, i + 1 + specWidth)])
            }
            if let f = fallback {
                return Array(draftTokens[(f + 1)..<min(draftTokens.count, f + 1 + specWidth)])
            }
            return []
        }

        var out = ""
        var pieceBuf = [CChar](repeating: 0, count: 256)
        var nPast = tokens.count             // prompt occupies positions 0..<tokens.count
        var emitted = 0
        var prevTok: llama_token? = nil
        var next = llama_sampler_sample(sampler, ctx, -1)

        /// Append one confirmed token's text; true = generation is finished.
        func emit(_ token: llama_token) -> Bool {
            if llama_token_is_eog(model, token) { return true }
            let n = llama_token_to_piece(model, token, &pieceBuf, Int32(pieceBuf.count), 0, true)
            if n > 0 {
                out += String(decoding: pieceBuf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            emitted += 1
            if let marker = Self.stopMarkers.first(where: { out.hasSuffix($0) }) {
                out.removeLast(marker.count)
                return true
            }
            return false
        }

        var accepted = 0, offered = 0
        decodeLoop: while emitted < maxTokens {
            if emit(next) { break }
            let spec = speculate(prev: prevTok, cur: next)
            offered += spec.count
            let run = [next] + spec
            var batch = llama_batch_init(Int32(run.count), 0, 1)
            for (i, t) in run.enumerated() {
                batch.token[i] = t
                batch.pos[i] = llama_pos(nPast + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = 1              // verify every position
            }
            batch.n_tokens = Int32(run.count)
            let ok = llama_decode(ctx, batch) == 0
            llama_batch_free(batch)
            guard ok else { break }

            // Walk the verifications: position i's argmax is the model's token AFTER run[i].
            var used = 0
            var follower = argmax(0)
            while used < spec.count, follower == spec[used] {
                used += 1
                follower = argmax(Int32(used))
            }
            accepted += used
            nPast += 1 + used
            if used < spec.count {
                // Drop the rejected KV tail so the cache matches what was really accepted.
                llama_kv_cache_seq_rm(ctx, 0, llama_pos(nPast), -1)
            }
            for j in 0..<used {
                prevTok = j == 0 ? next : spec[j - 1]
                if emit(spec[j]) { break decodeLoop }
            }
            prevTok = used == 0 ? next : spec[used - 1]
            next = follower
        }
        if offered > 0 {
            yapdiag("llama: speculative accepted \(accepted)/\(offered) draft tokens (\(emitted) emitted)")
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
        // A cleanup never legitimately needs more than about 1.5x the input: the guards
        // in runCleanup discard anything past 3x anyway, so generating the rest was pure
        // waste - a 278-word transcript ran 12.7 s while the model wrote 1085 words that
        // were then thrown away. Cap the generation to what could possibly be kept.
        let cap = Int32(min(1400, max(220, Double(text.count) / 3.0 * 1.6 + 80)))
        let raw = try await Task.detached(priority: .userInitiated) {
            try LlamaEngine.complete(modelPath: path, system: system, user: user, draft: text, maxTokens: cap)
        }.value
        return FoundationModelsTransformer.stripEditorialAnnotations(
            FoundationModelsTransformer.stripLeakedAppName(FoundationModelsTransformer.sanitize(raw), appName: appName),
            raw: text)
    }
}
