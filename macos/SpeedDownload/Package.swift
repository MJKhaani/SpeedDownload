// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeedDownload",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeedDownload", targets: ["SpeedDownload"]),
    ],
    targets: [
        .executableTarget(name: "SpeedDownload"),
    ],
    swiftLanguageModes: [.v5]
)
