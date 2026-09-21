// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AdTrackingKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AdTrackingKit", targets: ["AdTrackingKit"])
    ],
    targets: [
        .target(name: "AdTrackingKit"),
        .testTarget(name: "AdTrackingKitTests", dependencies: ["AdTrackingKit"])
    ]
)
