// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuietRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "QuietRecorder", targets: ["QuietRecorder"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "QuietRecorder",
            path: "Sources/QuietRecorder"
        )
    ],
    swiftLanguageModes: [.v5]
)
