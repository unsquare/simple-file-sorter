// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileSorterMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FileSorterMac", targets: ["FileSorterMac"])
    ],
    targets: [
        .executableTarget(
            name: "FileSorterMac",
            path: "Sources/FileSorterMac",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
