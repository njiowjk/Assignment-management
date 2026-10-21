// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniversityTaskManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "UniversityTaskManager",
            targets: ["UniversityTaskManager"]
        )
    ],
    targets: [
        .executableTarget(
            name: "UniversityTaskManager",
            path: "UniversityTaskManager"
        ),
        .testTarget(
            name: "UniversityTaskManagerTests",
            dependencies: ["UniversityTaskManager"],
            path: "UniversityTaskManagerTests"
        )
    ]
)

