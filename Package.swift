// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DiskMap", targets: ["DiskMap"]),
    ],
    targets: [
        .target(name: "DiskMapCore", path: "Sources/DiskMapCore"),
        .executableTarget(
            name: "DiskMap",
            dependencies: ["DiskMapCore"],
            path: "Sources/DiskMap",
            linkerSettings: [.linkedFramework("Quartz")]
        ),
        .executableTarget(
            name: "diskmap-checks",
            dependencies: ["DiskMapCore"],
            path: "Sources/DiskMapChecks"
        ),
    ]
)
