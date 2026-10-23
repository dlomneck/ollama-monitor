 // swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OllamaMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OllamaMonitor", targets: ["OllamaMonitor"])
    ],
    targets: [
        .executableTarget(name: "OllamaMonitor")
    ]
)
