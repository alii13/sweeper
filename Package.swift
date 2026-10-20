// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sweeper",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Sweeper")]
)
