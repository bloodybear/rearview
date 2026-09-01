// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rearview",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rearview", targets: ["Rearview"]),
        .executable(name: "BenchmarkFixture", targets: ["BenchmarkFixture"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Rearview",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        ),
        .executableTarget(name: "BenchmarkFixture"),
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
