// swift-tools-version: 6.2
import PackageDescription

// LabelIt builds on macOS (the app, its library and the CLI) and on Linux (the library and the CLI; the Windows port
// follows). The manifest picks each platform's pieces, as DigUp's does:
//
// - macOS: Apple's frameworks (Vision, ImageIO, AVFoundation, Apple Intelligence) and llama.cpp with Metal.
// - Linux: stb and libheif to decode pictures, Tesseract to read text, llama.cpp for the CPU (scripts/build-llama.sh
//   puts it and stb's header in Vendor/linux; libheif and Tesseract come from the system: see scripts/linux).
let vendor = "\(Context.packageDirectory)/Vendor"

#if os(macOS)
let llamaModule = "Sources/CLlama"
let llamaLibraries = "\(vendor)/llama/lib"
let coreDependencies: [Target.Dependency] = []
let platformDependencies: [Target.Dependency] = []
let platformTargets: [Target] = []
#else
let llamaModule = "Sources/CLlamaLinux"
let llamaLibraries = "\(vendor)/linux/llama/lib"
let coreDependencies: [Target.Dependency] = ["CLinux"]
let platformDependencies: [Target.Dependency] = ["CStb", "CHeif", "CTesseract"]
let platformTargets: [Target] = [
    // System headers Glibc's module leaves out (extended attributes).
    .systemLibrary(name: "CLinux"),
    // JPEG, PNG, GIF and BMP decoding (stb_image, compiled privately so it can't clash with llama.cpp's copy).
    .target(name: "CStb", cSettings: [.headerSearchPath("../../Vendor/linux/stb"), .unsafeFlags(["-w"])]),
    // HEIC and HEIF, the iPhone's photo format.
    .systemLibrary(name: "CHeif", pkgConfig: "libheif", providers: [.apt(["libheif-dev"])]),
    // Text in pictures.
    .systemLibrary(name: "CTesseract", pkgConfig: "tesseract", providers: [.apt(["libtesseract-dev"])]),
]
#endif

let package = Package(
    name: "LabelIt",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LabelItCore", targets: ["LabelItCore"]),
        .library(name: "LabelItPlatform", targets: ["LabelItPlatform"]),
        .library(name: "LabelItEmbedding", targets: ["LabelItEmbedding"]),
    ],
    targets: [
        // The pipeline: decide, name, rename, log. Plain Swift; runs anywhere.
        .target(name: "LabelItCore", dependencies: coreDependencies),
        // What each platform supplies: reading files, seeing pictures, watching folders.
        .target(name: "LabelItPlatform", dependencies: ["LabelItCore"] + platformDependencies),
        .systemLibrary(name: "CLlama", path: llamaModule),
        // EmbeddingGemma 2 on llama.cpp.
        .target(name: "LabelItEmbedding", dependencies: ["LabelItCore", "CLlama"],
                linkerSettings: [.unsafeFlags(["-L\(llamaLibraries)"])]),
        .executableTarget(name: "labelit-cli", dependencies: ["LabelItCore", "LabelItPlatform", "LabelItEmbedding"]),
        // Test images live in Tests/LabelItCoreTests/Fixtures, read by path (see Fixtures in PipelineTests).
        .testTarget(name: "LabelItCoreTests", dependencies: ["LabelItCore", "LabelItPlatform"],
                    exclude: ["Fixtures"]),
        .testTarget(name: "LabelItEmbeddingTests", dependencies: ["LabelItEmbedding", "LabelItPlatform"]),
    ] + platformTargets
)
