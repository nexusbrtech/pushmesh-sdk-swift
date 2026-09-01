// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "PushMeshSDK",
  // O macOS não é plataforma de produto — está aqui só para a suíte de testes
  // rodar com `swift test` em qualquer Mac, sem simulador. As peças de iOS
  // (swizzle, UNUserNotificationCenter, entitlement) não têm teste de unidade:
  // a prova delas é o ritual de fronteira no simulador, não esta suíte.
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "PushMeshSDK", targets: ["PushMeshSDK"]),
  ],
  targets: [
    .target(name: "PushMeshSDK"),
    .testTarget(name: "PushMeshSDKTests", dependencies: ["PushMeshSDK"]),
  ]
)
