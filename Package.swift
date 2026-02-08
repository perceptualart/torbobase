// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ORBBase",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ORBBase",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
