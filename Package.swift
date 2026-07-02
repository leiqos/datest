// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Datest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Datest",
            path: "Sources/Datest"
        )
    ]
)
