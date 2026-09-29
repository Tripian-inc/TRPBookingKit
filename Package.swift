// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TRPBookingKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(name: "TRPBookingKit", targets: ["TRPBookingKit"])
    ],
    targets: [
        .target(name: "TRPBookingKit"),
        .testTarget(
            name: "TRPBookingKitTests",
            dependencies: ["TRPBookingKit"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v5]
)
