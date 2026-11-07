// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iDisk",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "iDisk",
            dependencies: ["Core"],
            path: "Sources/iDisk"
        ),
        .executableTarget(
            name: "BenchTest",
            dependencies: ["Core"],
            path: "Sources/BenchTest"
        ),
        .executableTarget(
            name: "DumpDevices",
            dependencies: ["Core"],
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        )
    ]
)