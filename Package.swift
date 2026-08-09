// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Signalbox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Signalbox", targets: ["Signalbox"])
    ],
    targets: [
        .executableTarget(
            name: "Signalbox",
            path: "Sources/Signalbox",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SignalboxTests",
            dependencies: ["Signalbox"],
            path: "Tests/SignalboxTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
