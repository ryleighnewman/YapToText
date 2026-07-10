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
        ModelInfo(id: "apple", displayName: "Apple Speech", provider: "Apple",
                  kind: .speech, summary: "On-device streaming transcription with live text, no time limit. The instant fallback.",
                  languages: "43+ languages", sizeMB: 0, quality: 5,
                  downloadURL: nil, fileName: nil, runtime: .apple, license: "Apple system"),
        ModelInfo(id: "apple-foundation", displayName: "Apple Intelligence", provider: "Apple",
                  kind: .language, summary: "On-device Foundation model. Fallback while a downloaded cleanup model isn\u{2019}t installed.",
                  languages: "Multilingual", sizeMB: 0, quality: 5,
                  downloadURL: nil, fileName: nil, runtime: .apple, license: "Apple system"),

        // MARK: Speech - whisper.cpp GGML (Hugging Face ggerganov/whisper.cpp)
        ModelInfo(id: "whisper-tiny-en", displayName: "Whisper Tiny (English)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Fastest, lowest accuracy. Good for quick notes on older Macs.",
                  languages: "English", sizeMB: 75, quality: 2,
                  downloadURL: whisper("ggml-tiny.en.bin"), fileName: "ggml-tiny.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-base-en", displayName: "Whisper Base (English)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Fast and light with solid accuracy for everyday dictation.",
                  languages: "English", sizeMB: 142, quality: 3,
                  downloadURL: whisper("ggml-base.en.bin"), fileName: "ggml-base.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-small-en", displayName: "Whisper Small (English)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Noticeably more accurate; a good quality/speed balance.",
                  languages: "English", sizeMB: 466, quality: 4,
                  downloadURL: whisper("ggml-small.en.bin"), fileName: "ggml-small.en.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-base", displayName: "Whisper Base", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Fast and light, multilingual. Good for quick notes.",
                  languages: "Multilingual", sizeMB: 142, quality: 3,
                  downloadURL: whisper("ggml-base.bin"), fileName: "ggml-base.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-small", displayName: "Whisper Small", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Balanced accuracy and speed, multilingual.",
                  languages: "Multilingual", sizeMB: 466, quality: 4,
                  downloadURL: whisper("ggml-small.bin"), fileName: "ggml-small.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-medium", displayName: "Whisper Medium", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Strong accuracy, multilingual. Slower than Small.",
                  languages: "Multilingual", sizeMB: 1530, quality: 4,
                  downloadURL: whisper("ggml-medium.bin"), fileName: "ggml-medium.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo-q5", displayName: "Whisper Large v3 Turbo (Q5)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Near-large accuracy, quantized for speed. Multilingual. Recommended download.",
                  languages: "Multilingual", sizeMB: 574, quality: 5,
                  downloadURL: whisper("ggml-large-v3-turbo-q5_0.bin"), fileName: "ggml-large-v3-turbo-q5_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo-q8", displayName: "Whisper Large v3 Turbo (Q8)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Turbo model at higher-fidelity quantization. Great accuracy, still compact.",
                  languages: "Multilingual", sizeMB: 834, quality: 5,
                  downloadURL: whisper("ggml-large-v3-turbo-q8_0.bin"), fileName: "ggml-large-v3-turbo-q8_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Full turbo model. High accuracy, multilingual, fast on Apple Silicon.",
                  languages: "Multilingual", sizeMB: 1560, quality: 5,
                  downloadURL: whisper("ggml-large-v3-turbo.bin"), fileName: "ggml-large-v3-turbo.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3-q5", displayName: "Whisper Large v3 (Q5)", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Full large-v3 accuracy, quantized to save space. Slower than Turbo.",
                  languages: "Multilingual", sizeMB: 1080, quality: 5,
                  downloadURL: whisper("ggml-large-v3-q5_0.bin"), fileName: "ggml-large-v3-q5_0.bin",
                  runtime: .whisperCpp, license: "MIT"),
        ModelInfo(id: "whisper-large-v3", displayName: "Whisper Large v3", provider: "OpenAI / whisper.cpp",
                  kind: .speech, summary: "Highest accuracy, multilingual. Largest and slowest.",
                  languages: "Multilingual", sizeMB: 3100, quality: 5,
                  downloadURL: whisper("ggml-large-v3.bin"), fileName: "ggml-large-v3.bin",
                  runtime: .whisperCpp, license: "MIT"),

        // MARK: Language - GGUF for the optional cleanup stage (llama.cpp)
        ModelInfo(id: "phi-3.5-mini-instruct-q4", displayName: "Phi-3.5 Mini Instruct", provider: "Microsoft / llama.cpp",
                  kind: .language, summary: "The recommended cleanup model. MIT-licensed like Whisper, it follows rewrite instructions far more reliably than Apple Intelligence.",
                  languages: "Multilingual", sizeMB: 2390, quality: 5,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"),
                  fileName: "Phi-3.5-mini-instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "MIT"),
        ModelInfo(id: "llama-3.2-1b-instruct-q4", displayName: "Llama 3.2 1B Instruct", provider: "Meta / llama.cpp",
                  kind: .language, summary: "Tiny, fast cleanup model. Alternative to Apple Intelligence.",
                  languages: "Multilingual", sizeMB: 808, quality: 3,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
                  fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "Llama 3.2 Community"),
        ModelInfo(id: "llama-3.2-3b-instruct-q4", displayName: "Llama 3.2 3B Instruct", provider: "Meta / llama.cpp",
                  kind: .language, summary: "Higher-quality cleanup and formatting. Larger, slower.",
                  languages: "Multilingual", sizeMB: 2020, quality: 4,
                  downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
                  fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", runtime: .llamaCpp, license: "Llama 3.2 Community"),
    ]
}
