// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "dBDeck",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "dBDeck", targets: ["dBDeck"])
    ],
    targets: [
        .target(
            name: "AudioDSP",
            path: "Sources/AudioDSP",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "dBDeck",
            dependencies: ["AudioDSP"],
            path: "Sources/dBDeck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
