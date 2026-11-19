// swift-tools-version:5.9
//
// Pacchetto del modulo condiviso, utile per eseguire i test unitari
// del protocollo da Terminale con `swift test` (cartella Shared/).
// Le app NON dipendono da questo pacchetto: compilano direttamente i
// sorgenti di Sources/TabletCore e Sources/TabletLink (vedi project.yml).

import PackageDescription

let package = Package(
    name: "TabletShared",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TabletCore", targets: ["TabletCore"]),
    ],
    targets: [
        .target(name: "TabletCore", path: "Sources/TabletCore"),
        .testTarget(name: "TabletCoreTests", dependencies: ["TabletCore"], path: "Tests/TabletCoreTests"),
    ]
)
