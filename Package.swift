// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Audify",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Audify", targets: ["Audify"]),
        .library(name: "AudifyKit", targets: ["AudifyKit"]),
    ],
    targets: [
        .target(
            name: "AudifyKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "Audify",
            dependencies: ["AudifyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudifyKitTests",
            dependencies: ["AudifyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
