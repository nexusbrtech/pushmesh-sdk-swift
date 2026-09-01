Pod::Spec.new do |s|
  # PushMesh SDK nativo para iOS — o mesmo contrato do SDK de React Native,
  # sem React Native. A instalação primária é SPM (ver README); este podspec
  # existe para quem ainda usa CocoaPods.

  s.name             = 'PushMeshSDK'
  s.version          = '0.1.1'
  s.summary          = 'Push para apps Swift nativos, com recibo de entrega.'

  s.description      = <<-DESC
  SDK de push do PushMesh para apps Swift/UIKit/SwiftUI, sem React Native.
  Fala o mesmo contrato do SDK de JavaScript, usa as mesmas chaves de
  armazenamento (pm:*) — um app que migra mantém o mesmo player_id — e
  devolve o recibo de entrega, a promessa central do produto. Fila offline
  com backoff, jitter e Retry-After honrado.
  DESC

  s.homepage         = 'https://pushmesh.io'
  # TODO(dono): definir a licença do SDK antes de publicar — o repositório
  # monorepo não tem LICENSE. Este valor é placeholder.
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'PushMesh' => 'dev@pushmesh.io' }
  s.source           = { :git => 'https://github.com/pushmesh/sdk-swift.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/PushMeshSDK/*.swift'
end
