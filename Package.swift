// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hum",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Hum", path: "Sources/Hum")
    ]
)
