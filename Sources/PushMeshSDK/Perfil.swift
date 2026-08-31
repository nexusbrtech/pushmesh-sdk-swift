import Foundation
#if canImport(UIKit)
import UIKit
#endif

/** Versão deste SDK, reportada em `sdk_versao` — diagnóstico de campo sem chute. */
public let versaoDoSDK = "0.1.0-swift"

/**
 Perfil do aparelho.

 Regra aprendida na marra (2026-07-30): os nomes das chaves são CONTRATO. Mandar
 `modelo` em vez de `device_model` faz o servidor ignorar em silêncio — foi assim
 que o iOS ficou meses sem modelo no painel, sem um único erro em lugar nenhum.
 */
enum Perfil {
  /** Identificador de hardware ("iPhone17,2"). É o que o painel mostra. */
  static var modelo: String {
    var info = utsname()
    uname(&info)
    let espelho = Mirror(reflecting: info.machine)
    let bytes = espelho.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }
    let nome = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    // No simulador o `uname` devolve o Mac; o modelo real vem por variável de ambiente.
    if let simulado = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulado
    }
    return nome
  }

  static var sistema: String {
    #if canImport(UIKit)
    return UIDevice.current.systemVersion
    #else
    return ProcessInfo.processInfo.operatingSystemVersionString
    #endif
  }

  /** Idioma no formato que o servidor espera (pt-BR). */
  static var idioma: String? {
    guard let tag = Locale.preferredLanguages.first else { return nil }
    return tag
  }

  /** Fuso em SEGUNDOS a leste de UTC — o mesmo que o SDK de JS envia. */
  static var fusoEmSegundos: Int { TimeZone.current.secondsFromGMT() }

  static func campos(appVersion: String?) -> [String: Any] {
    var d: [String: Any] = [
      "device_model": modelo,
      "device_os": sistema,
      "fabricante": "Apple",
      "timezone": fusoEmSegundos,
      "sdk_versao": versaoDoSDK,
    ]
    if let idioma { d["language"] = idioma }
    if let appVersion { d["app_version"] = appVersion }
    return d
  }
}
