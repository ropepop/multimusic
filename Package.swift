// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultimusicCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MultimusicCore", targets: ["MultimusicCore"])],
    targets: [
        .target(name: "MultimusicCore", path: "Multimusic/Core"),
        .testTarget(name: "MultimusicCoreTests", dependencies: ["MultimusicCore"])
    ]
)
