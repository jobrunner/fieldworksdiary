// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FieldworksGeo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FieldworksGeo", targets: ["FieldworksGeo"])],
    targets: [
        .target(name: "FieldworksGeo", resources: [.copy("Resources/admin_labels.json")]),
        .testTarget(name: "FieldworksGeoTests", dependencies: ["FieldworksGeo"]),
    ]
)
