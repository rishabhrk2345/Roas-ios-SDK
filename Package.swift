// swift-tools-version:5.9
import PackageDescription

// ROASSensor iOS SDK. Open in Xcode, or `swift build` / `swift test`.
// The hash-parity tests are pure Foundation/CryptoKit and run on macOS without a
// simulator; the attribution code (ATT/IDFA/AdServices/StoreKit) needs a device.
let package = Package(
    name: "RoasSensor",
    // macOS is declared so `swift test` (the pure-Foundation/CryptoKit parity
    // tests) can run on the Mac host without a simulator — CryptoKit's SHA256
    // needs macOS 10.15+. The device attribution code is all `#if canImport`
    // guarded, so it no-ops on macOS rather than failing to build.
    platforms: [.iOS(.v14), .macOS(.v10_15)],
    products: [
        .library(name: "RoasSensor", targets: ["RoasSensor"]),
    ],
    targets: [
        .target(
            name: "RoasSensor",
            // The privacy manifest travels INSIDE the package, because App Store
            // Connect refuses an upload (ITMS-91053) whose binary calls a
            // required-reason API -- UserDefaults, file timestamps -- that no
            // manifest in the bundle declares, and those calls are this SDK's.
            // `.copy`, not `.process`: Xcode must find the file byte-for-byte
            // under its own name to merge it into the app's privacy report.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "RoasSensorTests", dependencies: ["RoasSensor"]),
    ]
)
