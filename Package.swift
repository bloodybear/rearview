// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rearview",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rearview", targets: ["Rearview"]),
        .executable(name: "NotionAXEvaluation", targets: ["NotionAXEvaluation"]),
        .executable(name: "BenchmarkFixture", targets: ["BenchmarkFixture"]),
        .executable(name: "NotionScenarios", targets: ["NotionScenarios"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Rearview",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "NotionAXCore", "NotionAXReportSupport"
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        ),
        .executableTarget(name: "BenchmarkFixture"),
        .target(name: "NotionAXCore"),
        .target(name: "NotionAXReportSupport", dependencies: ["NotionAXCore"]),
        .executableTarget(name: "NotionAXEvaluation", dependencies: ["NotionScenarioCore", "NotionAXCore", "NotionAXReportSupport"]),
        .target(name: "NotionScenarioCore"),
        .executableTarget(name: "NotionScenarios", dependencies: ["NotionScenarioCore"]),
        .testTarget(name: "NotionAXEvaluationTests", dependencies: ["NotionAXCore"]),
        .testTarget(name: "NotionAXCoreTests", dependencies: ["NotionAXCore"]),
        .testTarget(name: "NotionScenarioTests", dependencies: ["NotionScenarioCore"]),
        .testTarget(
            name: "RearviewTests",
            dependencies: ["Rearview"],
            path: "Tests/RearviewTests"
        ),
        .testTarget(
            name: "RearviewAppKitTests",
            dependencies: ["Rearview"],
            path: "Tests/RearviewAppKitTests"
        )
    ]
)
