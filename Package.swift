// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AOL-OS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AOLOS",
            path: "Sources/AOLOS",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
