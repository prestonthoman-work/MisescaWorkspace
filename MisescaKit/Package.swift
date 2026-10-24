// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MisescaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MisescaKit", targets: ["MisescaKit"])
    ],
    targets: [
        .target(name: "MisescaKit"),
        .testTarget(name: "MisescaKitTests", dependencies: ["MisescaKit"])
    ]
)
