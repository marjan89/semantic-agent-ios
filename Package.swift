// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemanticAgent",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SemanticAgent", targets: ["SemanticAgent", "MockBootstrap"]),
    ],
    targets: [
        .target(
            name: "SemanticAgent",
            path: "Sources/SemanticAgent"
        ),
        .target(
            name: "MockBootstrap",
            path: "Sources/MockBootstrap",
            publicHeadersPath: "include"
        ),
    ]
)
