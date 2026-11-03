// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LingChongDao",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LingChongDao", targets: ["LingChongDao"]),
        .executable(name: "lingchongdao-hook", targets: ["IslandHook"]),
        .executable(name: "lingchongdao-verify", targets: ["IslandVerification"]),
        .executable(name: "lingchongdao-pet-verify", targets: ["PetVerification"]),
        .executable(name: "lingchongdao-origin-verify", targets: ["OriginVerification"]),
        .library(name: "IslandCore", targets: ["IslandCore"]),
        .library(name: "IslandPets", targets: ["IslandPets"]),
        .library(name: "IslandConnections", targets: ["IslandConnections"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "IslandPets", dependencies: ["IslandCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "IslandConnections", dependencies: ["IslandCore"], path: "Sources/LingChongDao/Connections"),
        .executableTarget(name: "LingChongDao", dependencies: ["IslandCore", "IslandConnections", "IslandPets", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Connections"], linkerSettings: [.linkedFramework("IOKit"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "IslandHook", dependencies: ["IslandCore"]),
        .executableTarget(name: "IslandVerification", dependencies: ["IslandCore", "IslandConnections"], path: "Tests/Verification", exclude: ["README.md"]),
        .executableTarget(name: "PetVerification", dependencies: ["IslandPets", "IslandCore"], path: "Tests/PetVerification"),
        .executableTarget(name: "OriginVerification", dependencies: ["IslandCore"], path: "Tests/OriginVerification"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "ConnectionTests", dependencies: ["IslandConnections"])
    ],
    swiftLanguageModes: [.v5]
)
