// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniversalExtractor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UniversalExtractorCore", targets: ["UniversalExtractorCore"]),
        .executable(name: "UniversalExtractorApp", targets: ["UniversalExtractorApp"]),
    ],
    targets: [
        .target(name: "UniversalExtractorCore"),
        .executableTarget(
            name: "UniversalExtractorApp",
            dependencies: ["UniversalExtractorCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["UniversalExtractorCore"]
        ),
        .executableTarget(
            name: "EngineChecks",
            dependencies: ["UniversalExtractorCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
