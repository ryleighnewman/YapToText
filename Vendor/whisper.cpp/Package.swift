// swift-tools-version:5.9
// Local source-building package over the vendored whisper.cpp v1.7.4 tree
// (upstream's Package.swift at this tag was only a pkg-config stub).
// Metal + Accelerate, Apple Silicon.
import PackageDescription

let package = Package(
    name: "whisper",
    platforms: [.macOS(.v13)],
    products: [.library(name: "whisper", targets: ["whisper"])],
    targets: [
        .target(
            name: "whisper",
            path: ".",
            exclude: [
                "bindings", "cmake", "examples", "models", "samples", "scripts", "tests",
                "src/coreml", "src/openvino", "ggml/cmake", "grammars",
            ],
            sources: [
                "src/whisper.cpp",
                "ggml/src/ggml.c",
                "ggml/src/ggml-alloc.c",
                "ggml/src/ggml-backend.cpp",
                "ggml/src/ggml-backend-reg.cpp",
                "ggml/src/ggml-opt.cpp",
                "ggml/src/ggml-quants.c",
                "ggml/src/ggml-threading.cpp",
                "ggml/src/ggml-cpu/ggml-cpu.c",
                "ggml/src/ggml-cpu/ggml-cpu.cpp",
                "ggml/src/ggml-cpu/ggml-cpu-aarch64.cpp",
                "ggml/src/ggml-cpu/ggml-cpu-quants.c",
                "ggml/src/ggml-cpu/ggml-cpu-traits.cpp",
                "ggml/src/ggml-cpu/llamafile/sgemm.cpp",
                "ggml/src/ggml-metal/ggml-metal.m",
                "ggml/src/ggml-blas/ggml-blas.cpp",
                "llama/src",
            ],
            resources: [.process("ggml/src/ggml-metal/ggml-metal.metal")],
            publicHeadersPath: "spm-headers",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/src/ggml-cpu"),
                .headerSearchPath("llama/include"),
                .headerSearchPath("llama/src"),
                .define("GGML_USE_CPU"),      // registers the CPU device in ggml's backend REGISTRY - without it llama's loader (make_cpu_buft_list) gets a null CPU device and segfaults; whisper never noticed because it does not use the registry
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("GGML_USE_METAL"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("NDEBUG"),
                .unsafeFlags(["-O3", "-fno-objc-arc"]),
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/src/ggml-cpu"),
                .headerSearchPath("llama/include"),
                .headerSearchPath("llama/src"),
                .define("GGML_USE_CPU"),      // registers the CPU device in ggml's backend REGISTRY - without it llama's loader (make_cpu_buft_list) gets a null CPU device and segfaults; whisper never noticed because it does not use the registry
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("GGML_USE_METAL"),
                .define("NDEBUG"),
                .unsafeFlags(["-O3"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .cxx17
)
