import Foundation

/**
 Armazenamento local do SDK.

 Usa as MESMAS chaves do SDK de React Native (`pm:*`). Não é enfeite: um app que
 migra de RN para Swift nativo — ou que roda os dois lados durante a migração —
 mantém o mesmo `player_id` e não vira um aparelho duplicado no painel, nem perde
 o histórico de entrega.
 */
enum Chave: String {
  case token = "pm:token"
  case playerId = "pm:player_id"
  case regHash = "pm:reg_hash"
  case transporte = "pm:transporte"
  case tiposNotificacao = "pm:notif_types"
  case usuarioExterno = "pm:external_user_id"
  case sessoes = "pm:sessoes"
  case lruRecibos = "pm:receipt_lru"
  case fila = "pm:fila"
  case filaEmVoo = "pm:fila_em_voo"
  case saidaPendente = "pm:logout_pendente"
}

/**
 Guarda em `UserDefaults`.

 Escolha deliberada sobre Keychain: nada aqui é segredo. O token do APNs é
 público por natureza (o servidor é quem guarda a chave que assina), e o
 `player_id` é um identificador opaco. Keychain sobrevive à desinstalação, o que
 seria PIOR: o aparelho reinstalado herdaria um registro velho com um token que o
 APNs já invalidou.
 */
struct Armazenamento {
  private let defaults: UserDefaults
  private let prefixo: String

  init(defaults: UserDefaults = .standard, prefixo: String = "") {
    self.defaults = defaults
    self.prefixo = prefixo
  }

  private func nome(_ chave: Chave) -> String { prefixo + chave.rawValue }

  func texto(_ chave: Chave) -> String? { defaults.string(forKey: nome(chave)) }
  func inteiro(_ chave: Chave) -> Int? {
    defaults.object(forKey: nome(chave)) == nil ? nil : defaults.integer(forKey: nome(chave))
  }
  func lista(_ chave: Chave) -> [String] { defaults.stringArray(forKey: nome(chave)) ?? [] }

  func guardar(_ valor: String?, em chave: Chave) {
    if let valor { defaults.set(valor, forKey: nome(chave)) } else { defaults.removeObject(forKey: nome(chave)) }
  }
  func guardar(_ valor: Int, em chave: Chave) { defaults.set(valor, forKey: nome(chave)) }
  func guardar(_ valor: [String], em chave: Chave) { defaults.set(valor, forKey: nome(chave)) }
  func apagar(_ chave: Chave) { defaults.removeObject(forKey: nome(chave)) }
}
