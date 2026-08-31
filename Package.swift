// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "PushMeshSDK",
  platforms: [.iOS(.v15)],
  products: [
    .library(name: "PushMeshSDK", targets: ["PushMeshSDK"]),
  ],
  targets: [
    // Sem alvo de testes ainda — declarar um alvo vazio quebra o `swift build`
    // de quem baixa o pacote. Os testes entram junto com o primeiro release.
    .target(name: "PushMeshSDK"),
  ]
)
