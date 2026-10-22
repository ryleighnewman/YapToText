import Foundation

/// Curated catalog of models the user can run. Built-in Apple engines need no download;
/// speech models are whisper.cpp GGML single files from Hugging Face (ggerganov/whisper.cpp);
/// language models are GGUF single files for the optional cleanup stage.
///
/// NOTE: download sizes are approximate. This list is refreshed against live sources; the
/// framework (download, storage, selection, management) is engine-agnostic, so entries can
/// be added or corrected without touching the rest of the app.
enum ModelCatalog {
    private static func whisper(_ file: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }

    static let all: [ModelInfo] = [

        // MARK: Built-in (no download)
        ModelInfo(id: "apple-foundation", displayName: String(localized: "Apple Intelligence"), provider: "Apple",
                  kind: .language, summary: String(localized: "On-device Foundation model. Fallback while a downloaded cleanup model isn\u{2019}t installed."),
                  languages: String(localized: "Multilingual"), sizeMB: 0, quality: 5, speed: 4,
                  downloadURL: nil, fileName: nil, runtime: .apple, license: String(localized: "Apple system")),

        // MARK: Speech - whisper.cpp GGML (Hugging Face ggerganov/whisper.cpp)
        ModelInfo(id: "whisper-tiny-en", displayName: String(localized: "Whisper Tiny (English)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Fastest, lowest accuracy. Good for quick notes on older Macs."),
                  languages: String(localized: "English"), sizeMB: 75, quality: 2, speed: 5,
                  downloadURL: whisper("ggml-tiny.en.bin"), fileName: "ggml-tiny.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-base-en", displayName: String(localized: "Whisper Base (English)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Fast and light with solid accuracy for everyday dictation."),
                  languages: String(localized: "English"), sizeMB: 142, quality: 3, speed: 5,
                  downloadURL: whisper("ggml-base.en.bin"), fileName: "ggml-base.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-small-en", displayName: String(localized: "Whisper Small (English)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Noticeably more accurate; a good quality/speed balance."),
                  languages: String(localized: "English"), sizeMB: 466, quality: 4, speed: 4,
                  downloadURL: whisper("ggml-small.en.bin"), fileName: "ggml-small.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-base", displayName: String(localized: "Whisper Base"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Fast and light, multilingual. Good for quick notes."),
                  languages: String(localized: "Multilingual"), sizeMB: 142, quality: 3, speed: 5,
                  downloadURL: whisper("ggml-base.bin"), fileName: "ggml-base.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-small", displayName: String(localized: "Whisper Small"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Balanced accuracy and speed, multilingual."),
                  languages: String(localized: "Multilingual"), sizeMB: 466, quality: 4, speed: 4,
                  downloadURL: whisper("ggml-small.bin"), fileName: "ggml-small.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-medium", displayName: String(localized: "Whisper Medium"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Strong accuracy, multilingual. Slower than Small."),
                  languages: String(localized: "Multilingual"), sizeMB: 1530, quality: 4, speed: 2,
                  downloadURL: whisper("ggml-medium.bin"), fileName: "ggml-medium.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo-q5", displayName: String(localized: "Whisper Large v3 Turbo (Q5)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Near-large accuracy, quantized for speed. Multilingual. Recommended download."),
                  languages: String(localized: "Multilingual"), sizeMB: 574, quality: 5, speed: 5, recommended: true,
                  downloadURL: whisper("ggml-large-v3-turbo-q5_0.bin"), fileName: "ggml-large-v3-turbo-q5_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo-q8", displayName: String(localized: "Whisper Large v3 Turbo (Q8)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Turbo model at higher-fidelity quantization. Great accuracy, still compact."),
                  languages: String(localized: "Multilingual"), sizeMB: 834, quality: 5, speed: 4,
                  downloadURL: whisper("ggml-large-v3-turbo-q8_0.bin"), fileName: "ggml-large-v3-turbo-q8_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo", displayName: String(localized: "Whisper Large v3 Turbo"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Full turbo model. High accuracy, multilingual, fast on Apple Silicon."),
                  languages: String(localized: "Multilingual"), sizeMB: 1560, quality: 5, speed: 3,
                  downloadURL: whisper("ggml-large-v3-turbo.bin"), fileName: "ggml-large-v3-turbo.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-q5", displayName: String(localized: "Whisper Large v3 (Q5)"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Full large-v3 accuracy, quantized to save space. Slower than Turbo."),
                  languages: String(localized: "Multilingual"), sizeMB: 1080, quality: 5, speed: 2,
                  downloadURL: whisper("ggml-large-v3-q5_0.bin"), fileName: "ggml-large-v3-q5_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3", displayName: String(localized: "Whisper Large v3"), provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: String(localized: "Highest accuracy, multilingual. Largest and slowest."),
                  languages: String(localized: "Multilingual"), sizeMB: 3100, quality: 5, speed: 1,
                  downloadURL: whisper("ggml-large-v3.bin"), fileName: "ggml-large-v3.bin",
                  runtime: .whisperCpp, license: "MIT"),

        // MARK: Language - GGUF for the optional cleanup stage (llama.cpp)
        ModelInfo(id: "phi-3.5-mini-instruct-q4", displayName: String(localized: "Phi-3.5 Mini Instruct"), provider: "Microsoft / llama.cpp",
                  kind: .language, summary: String(localized: "The recommended cleanup model. MIT-licensed like Whisper, it follows rewrite instructions far more reliably than Apple Intelligence."),
                  languages: String(localized: "Multilingual"), sizeMB: 2390, quality: 5, speed: 3, recommended: true,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"),
                  fileName: "Phi-3.5-mini-instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "MIT"),
        ModelInfo(id: "llama-3.2-1b-instruct-q4", displayName: String(localized: "Llama 3.2 1B Instruct"), provider: "Meta / llama.cpp",
                  kind: .language, summary: String(localized: "Tiny, fast cleanup model. Alternative to Apple Intelligence."),
                  languages: String(localized: "Multilingual"), sizeMB: 808, quality: 3, speed: 5,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
                  fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "Llama 3.2 Community"),
        ModelInfo(id: "llama-3.2-3b-instruct-q4", displayName: String(localized: "Llama 3.2 3B Instruct"), provider: "Meta / llama.cpp",
                  kind: .language, summary: String(localized: "Higher-quality cleanup and formatting. Larger, slower."),
                  languages: String(localized: "Multilingual"), sizeMB: 2020, quality: 4, speed: 3,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
                  fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "Llama 3.2 Community"),
        ModelInfo(id: "qwen-2.5-3b-instruct-q4", displayName: String(localized: "Qwen 2.5 3B Instruct"), provider: "Alibaba / llama.cpp",
                  kind: .language, summary: String(localized: "Excellent multilingual cleanup, especially for non-English dictation."),
                  languages: String(localized: "Multilingual (29+)"), sizeMB: 1930, quality: 4, speed: 3,
                  downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"),
                  fileName: "qwen2.5-3b-instruct-q4_k_m.gguf", runtime: .llamaCpp, license: "Qwen Research"),
        ModelInfo(id: "qwen-2.5-1.5b-instruct-q4", displayName: String(localized: "Qwen 2.5 1.5B Instruct"), provider: "Alibaba / llama.cpp",
                  kind: .language, summary: String(localized: "Small and quick with strong multilingual coverage."),
                  languages: String(localized: "Multilingual (29+)"), sizeMB: 990, quality: 3, speed: 4,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"),
                  fileName: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "Apache 2.0"),
        ModelInfo(id: "gemma-2-2b-it-q4", displayName: String(localized: "Gemma 2 2B"), provider: "Google / llama.cpp",
                  kind: .language, summary: String(localized: "Balanced cleanup quality and speed."),
                  languages: String(localized: "Multilingual"), sizeMB: 1710, quality: 3, speed: 4,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"),
                  fileName: "gemma-2-2b-it-Q4_K_M.gguf", runtime: .llamaCpp, license: "Gemma"),
    ]
}
