// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pausa",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Pausa", targets: ["Pausa"])],
    targets: [
        .target(name: "PausaCore"),
        .executableTarget(name: "Pausa", dependencies: ["PausaCore"]),
        .testTarget(name: "PausaCoreTests", dependencies: ["PausaCore"])
    ],
    swiftLanguageModes: [.v5]
)
