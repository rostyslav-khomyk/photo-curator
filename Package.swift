// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhotoCurator",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PhotoCurator", targets: ["PhotoCurator"])],
    targets: [
        .executableTarget(
            name: "PhotoCurator",
            path: "Sources/PhotoCurator"
        ),
        .testTarget(name: "PhotoCuratorTests", dependencies: ["PhotoCurator"])
    ]
)
