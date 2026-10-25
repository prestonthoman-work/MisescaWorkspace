// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MisescaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MisescaKit", targets: ["MisescaKit"])
    ],
    targets: [
        // Reading diagrams is heavy pixel work; keep it optimized even in Debug builds run from Xcode.
        .target(name: "MisescaKit", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "MisescaKitTests", dependencies: ["MisescaKit"])
    ]
)
