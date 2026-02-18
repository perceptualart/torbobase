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
#else
let dependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
let extraTargets: [Target] = []
#endif

let package = Package(
    name: "TorboBase",
    platforms: [.macOS(.v13)],
    dependencies: dependencies,
    targets: extraTargets + [
        .executableTarget(
            name: "TorboBase",
            dependencies: targetDependencies,
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
