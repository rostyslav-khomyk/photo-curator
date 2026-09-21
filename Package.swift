// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhotoRelay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PhotoRelay", targets: ["PhotoRelay"])],
    targets: [
        .executableTarget(
            name: "PhotoRelay",
            path: "Sources/PhotoRelay"
        ),
        .testTarget(name: "PhotoRelayTests", dependencies: ["PhotoRelay"])
    ]
)
