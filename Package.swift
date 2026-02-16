// swift-tools-version: 5.10
import PackageDescription

#if os(Linux)
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
]
#else
let dependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "TorboBase",
    platforms: [.macOS(.v13)],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "TorboBase",
            dependencies: targetDependencies,
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
