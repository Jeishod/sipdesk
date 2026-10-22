// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dependency = root.appendingPathComponent(".dependencies/pjsip").path

let package = Package(
    name: "SIPDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SIPDesk", targets: ["SIPDesk"]),
        .executable(name: "SIPProbe", targets: ["SIPProbe"])
    ],
    targets: [
        .target(
            name: "SIPBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", "\(dependency)/include"]),
                .define("PJ_AUTOCONF", to: "1")
            ],
            linkerSettings: [
                .unsafeFlags(["\(dependency)/lib/libSIPStack.a"]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedLibrary("c++")
            ]
        ),
        .target(name: "SIPCore", resources: [.copy("Localization")]),
        .target(name: "SIPRuntime", dependencies: ["SIPCore", "SIPBridge"]),
        .executableTarget(name: "SIPDesk", dependencies: ["SIPCore", "SIPRuntime"]),
        .executableTarget(name: "SIPProbe", dependencies: ["SIPCore", "SIPBridge"]),
        .testTarget(name: "SIPCoreTests", dependencies: ["SIPCore"]),
        .testTarget(name: "SIPRuntimeTests", dependencies: ["SIPRuntime", "SIPCore"])
    ]
)

