// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FieldworksGeo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FieldworksGeo", targets: ["FieldworksGeo"])],
    targets: [
        .target(name: "CGeotrans", path: "Sources/CGeotrans", publicHeadersPath: "include"),
        .target(name: "FieldworksGeo", dependencies: ["CGeotrans"], resources: [.copy("Resources/admin_labels.json")]),
        .testTarget(name: "FieldworksGeoTests", dependencies: ["FieldworksGeo"])
    ]
)
