// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DontSleepGUI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DontSleep", targets: ["DontSleep"])
    ],
    targets: [
        .executableTarget(name: "DontSleep")
    ]
)
