// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TimeTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TimeTracker",
            path: "Sources/TimeTracker"
        )
    ]
)
