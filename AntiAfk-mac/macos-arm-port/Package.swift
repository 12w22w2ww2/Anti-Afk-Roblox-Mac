// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AntiAFKRBXMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "antiafk-rbx-mac", targets: ["AntiAFKRBXMac"]),
        .executable(name: "AntiAFK-RBX", targets: ["AntiAFKRBXMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "AntiAFKRBXMac",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "AntiAFKRBXMacApp",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
