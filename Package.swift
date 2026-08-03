// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RustDeskNative",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VideoPipeline", targets: ["VideoPipeline"]),
        .library(name: "CoreBridge", targets: ["CoreBridge"]),
        .library(name: "ViewerInput", targets: ["ViewerInput"]),
        .library(name: "ConnectionCatalog", targets: ["ConnectionCatalog"]),
        .executable(name: "RustDeskNative", targets: ["RustDeskNative"]),
    ],
    targets: [
        .target(
            name: "CoreBridgeShim",
            path: "CoreBridge",
            exclude: ["RustDeskPatch", "README.md"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(name: "CoreBridge", dependencies: ["CoreBridgeShim"]),
        .target(name: "VideoPipeline"),
        .target(name: "ViewerInput", dependencies: ["CoreBridge"]),
        .target(
            name: "ConnectionCatalog",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "RustDeskNative",
            dependencies: ["VideoPipeline", "CoreBridge", "ViewerInput", "ConnectionCatalog"]
        ),
        .testTarget(
            name: "VideoPipelineTests",
            dependencies: ["VideoPipeline"]
        ),
        .testTarget(
            name: "CoreBridgeTests",
            dependencies: ["CoreBridge", "VideoPipeline"]
        ),
        .testTarget(
            name: "ViewerInputTests",
            dependencies: ["ViewerInput", "CoreBridge"]
        ),
        .testTarget(
            name: "ConnectionCatalogTests",
            dependencies: ["ConnectionCatalog"]
        ),
    ]
)
