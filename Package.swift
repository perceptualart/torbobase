// swift-tools-version: 5.10
import PackageDescription

#if os(Linux)
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "Crypto", package: "swift-crypto"),
    "CSQLite3",
]
let extraTargets: [Target] = [
    .systemLibrary(
        name: "CSQLite3",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    ),
]
let piperTargets: [Target] = []
let piperDeps: [Target.Dependency] = []
let piperSwiftSettings: [SwiftSetting] = []
let piperLinkerSettings: [LinkerSetting] = []
#else
let dependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
let extraTargets: [Target] = []

// sherpa-onnx Piper TTS — on-device voice synthesis (macOS only)
// Phase 6.1: Re-enabled with async initialization to prevent main thread blocking.
let sherpaLibDir = "Frameworks/macOS"
let piperTargets: [Target] = [
    .target(
        name: "CSherpaOnnx",
        path: "Sources/CSherpaOnnx",
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags(["-L\(sherpaLibDir)"]),
            .linkedLibrary("sherpa-onnx-c-api"),
            .linkedLibrary("onnxruntime"),
        ]
    ),
]
let piperDeps: [Target.Dependency] = ["CSherpaOnnx"]
let piperSwiftSettings: [SwiftSetting] = [.define("PIPER_TTS")]
let piperLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(sherpaLibDir)", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks/macOS"]),
]
#endif

let package = Package(
    name: "TorboBase",
    platforms: [.macOS(.v13)],
    dependencies: dependencies,
    targets: extraTargets + piperTargets + [
        .executableTarget(
            name: "TorboBase",
            dependencies: targetDependencies + piperDeps,
            swiftSettings: piperSwiftSettings,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ] + piperLinkerSettings
        )
    ]
)
