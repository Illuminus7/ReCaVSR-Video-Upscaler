// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReCaVSR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReCaVSR",
            path: "Sources/ReCaVSR"
        )
    ]
)
