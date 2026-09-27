// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordingBeanCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "RecordingBeanCore", targets: ["RecordingBeanCore"])],
    targets: [
        .target(name: "RecordingBeanCore"),
        .testTarget(name: "RecordingBeanCoreTests", dependencies: ["RecordingBeanCore"])
    ]
)
