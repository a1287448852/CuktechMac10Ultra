// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CuktechMac10Ultra",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CuktechCore", targets: ["CuktechCore"]),
        .executable(name: "CuktechMac10Ultra", targets: ["CuktechMac10Ultra"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMajor(from: "3.0.0")),
    ],
    targets: [
        .target(
            name: "CuktechCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/CuktechCore"
        ),
        .target(
            name: "CuktechBle",
            dependencies: ["CuktechCore"],
            path: "Sources/CuktechBle"
        ),
        .executableTarget(
            name: "CuktechMac10Ultra",
            dependencies: ["CuktechCore", "CuktechBle"],
            path: "Sources/CuktechMac10Ultra"
        ),
        .testTarget(
            name: "CuktechCoreTests",
            dependencies: ["CuktechCore"],
            path: "Tests/CuktechCoreTests"
        ),
        .testTarget(
            name: "CuktechBleTests",
            dependencies: ["CuktechBle"],
            path: "Tests/CuktechBleTests"
        ),
    ]
)
