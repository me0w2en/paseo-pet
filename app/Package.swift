// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaseoPet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PaseoPet", path: "Sources/PaseoPet")
    ]
)
