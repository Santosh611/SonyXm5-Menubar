// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SonyBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SonyBar",
            path: "Sources/SonyBar",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
