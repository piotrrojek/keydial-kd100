// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kd100",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "kd100",
            path: "Sources/kd100",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "kd100Tests",
            dependencies: ["kd100"],
            path: "Tests/kd100Tests"
        ),
    ]
)
