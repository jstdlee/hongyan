// swift-tools-version:6.0
import PackageDescription

// HongyanCore holds everything that does not need PhotoKit: S3 signing and
// client, key layout, scheduling, retention and the backup engine itself.
// Tests run on the iOS Simulator (see .github/workflows/ci.yml).
let package = Package(
    name: "HongyanCore",
    platforms: [.iOS("26.1")],
    products: [
        .library(name: "HongyanCore", targets: ["HongyanCore"]),
    ],
    targets: [
        .target(name: "HongyanCore"),
        .testTarget(name: "HongyanCoreTests", dependencies: ["HongyanCore"]),
    ],
    swiftLanguageModes: [.v5]
)
