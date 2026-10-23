 // swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OllamaMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OllamaMonitor", targets: ["OllamaMonitor"])
    ],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(
            name: "OllamaMonitor",
            dependencies: ["MonitorCore"],
            exclude: [
                "main.swift.backup-20261010-002831",
                "main.swift.backup-20261010-003556"
            ]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        )
    ]
)
