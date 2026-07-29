// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "XDecode",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "XDecodeCore", targets: ["XDecodeCore"]),
        .executable(name: "XDecode", targets: ["XDecodeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aperedera/SwiftZSTD.git", exact: "1.0.1"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib"
        ),
        .target(
            name: "XDecodeCore",
            dependencies: [
                "CZlib",
                .product(name: "SwiftZSTD", package: "SwiftZSTD"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "XDecodeApp",
            dependencies: ["XDecodeCore"],
            path: "XDecodeApp",
            exclude: ["Assets.xcassets", "Info.plist", "XDecode.entitlements"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "XDecodeCoreTests",
            dependencies: [
                "XDecodeCore",
                "CZlib",
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "XDecodeAppTests",
            dependencies: ["XDecodeApp"]
        ),
    ]
)
