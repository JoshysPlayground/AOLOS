// swift-tools-version:5.10
import Foundation
import PackageDescription

// Embedding Info.plist gives the unbundled debug binary the privacy usage strings that Photos access requires.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Info.plist").path

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
                .linkedFramework("Photos"),
                .linkedFramework("AVKit"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(
            name: "AOLOSTests",
            dependencies: ["AOLOS"],
            path: "Tests/AOLOSTests"
        ),
    ]
)
