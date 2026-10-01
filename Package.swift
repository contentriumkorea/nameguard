// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NameGuard", platforms: [.macOS(.v13)], products: [
    .executable(name: "nameguard", targets: ["nameguard"])
], targets: [
    .target(name: "NameGuard"),
    .target(name: "NameGuardMenu", dependencies: ["NameGuard"]),
    .executableTarget(name: "nameguard", dependencies: ["NameGuard", "NameGuardMenu"], path: "Sources/NameGuardCLI"),
    .testTarget(name: "NameGuardTests", dependencies: ["NameGuard"])
])
