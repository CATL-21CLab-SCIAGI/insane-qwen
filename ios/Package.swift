// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmbryoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "EmbryoCore", targets: ["EmbryoCore"])],
    targets: [
        .target(name: "EmbryoCore", path: "Embryo/Core"),
        .target(name: "EmbryoRecords", dependencies: ["EmbryoCore"], path: "Embryo/App",
                exclude: ["EmbryoApp.swift", "EmbryoStore.swift", "TokenVault.swift", "DevelopmentVerification.swift"], sources: ["RunRecord.swift"]),
        .testTarget(name: "EmbryoCoreTests", dependencies: ["EmbryoCore"], path: "Tests/EmbryoCoreTests"),
        .testTarget(name: "EmbryoRecordTests", dependencies: ["EmbryoCore", "EmbryoRecords"], path: "Tests/EmbryoRecordTests")
    ]
)
