// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DSMKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DSMKit", targets: ["DSMKit"]),
        .library(name: "DSMSSH", targets: ["DSMSSH"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
    ],
    dependencies: [
        // Pinned: 0.11.1 is the last release built on the Citadel author's own swift-nio-ssh fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.11.1"),
        // Only for MD5 on Linux test runs; Apple platforms use CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(name: "DSMKit"),
        .target(name: "DSMSSH", dependencies: [.product(name: "Citadel", package: "Citadel")]),
        .target(name: "MediaKit", dependencies: [
            "DSMKit",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .testTarget(name: "DSMKitTests", dependencies: ["DSMKit"]),
        .testTarget(name: "DSMSSHTests", dependencies: ["DSMSSH"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"]),
    ]
)
