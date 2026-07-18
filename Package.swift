// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PlugPilot",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CShim",
            path: "Sources/CShim"
        ),
        .executableTarget(
            name: "PlugPilotHelper",
            dependencies: ["CShim"],
            path: "Sources/PlugPilotHelper",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "PlugPilot",
            dependencies: ["CShim"],
            path: "Sources/PlugPilot",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
