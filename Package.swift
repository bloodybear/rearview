// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rearview",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Rearview", targets: ["Rearview"]),
        .executable(name: "BenchmarkFixture", targets: ["BenchmarkFixture"])
    ],
    targets: [
        .executableTarget(
            name: "Rearview",
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
