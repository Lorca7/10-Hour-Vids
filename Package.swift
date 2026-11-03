// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TenHourVids",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TenHourVids",
            path: "Sources/TenHourVids"
        )
    ]
)
