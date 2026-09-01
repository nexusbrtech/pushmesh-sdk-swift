import Foundation
import XCTest
@testable import PushMeshSDK

/**
 Montagem do payload de registro e peças pequenas.

 O conjunto de chaves é CONTRATO com o backend e com o SDK de JS
 (`sdk/src/players.ts` → `buildRegisterPayload`): o servidor ignora em
 silêncio chave com nome fora do contrato — foi assim que o iOS ficou meses
 sem modelo no painel, sem um único erro em lugar nenhum. Por isso se testa
 IGUALDADE DE CONJUNTO, não "contém": chave faltando E chave sobrando são
 defeitos.
 */
final class PayloadDeRegistroTests: XCTestCase {

  /// R1: o conjunto EXATO de chaves do contrato — nem a mais, nem a menos.
  func testConjuntoExatoDeChaves() {
    let completo = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: "u-1",
      saidaPendente: false, appVersion: "1.2.3")
    XCTAssertEqual(Set(completo.keys), [
      "app_id", "identifier", "device_type", "transporte",
      "external_user_id", "app_version",
      "device_model", "device_os", "fabricante", "timezone", "sdk_versao", "language",
    ])

    let minimo = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil,
      saidaPendente: false, appVersion: nil)
    XCTAssertEqual(Set(minimo.keys), [
      "app_id", "identifier", "device_type", "transporte",
      "device_model", "device_os", "fabricante", "timezone", "sdk_versao", "language",
    ])
  }

  /// R2: iOS é `device_type: 0` e o transporte é `apns` — APNs direto, sem
  /// Firebase. O servidor assume 'fcm' quando o campo falta; errar aqui manda
  /// o push pelo transporte errado e a entrega se perde em silêncio.
  func testValoresDeContratoDoIOS() {
    let payload = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    XCTAssertEqual(payload["device_type"] as? Int, 0)
    XCTAssertEqual(payload["transporte"] as? String, "apns")
    XCTAssertEqual(payload["identifier"] as? String, "tok")
    XCTAssertEqual(payload["app_id"] as? String, "app")
    XCTAssertEqual(payload["fabricante"] as? String, "Apple")
    XCTAssertEqual(payload["sdk_versao"] as? String, versaoDoSDK)
  }

  /// R3: `timezone` é INTEIRO em segundos — mandar nome IANA faz o servidor
  /// devolver 400 e o aparelho NUNCA registrar (silencioso: o app só vê
  /// `player: null`).
  func testFusoÉInteiroEmSegundos() {
    let payload = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    let fuso = payload["timezone"]
    XCTAssertTrue(fuso is Int, "o contrato é offset em segundos, não nome IANA")
    XCTAssertEqual((fuso as? Int), TimeZone.current.secondsFromGMT())
  }

  /// R4: TRI-STATE do `external_user_id` — string amarra, campo AUSENTE não
  /// mexe, null EXPLÍCITO limpa o logout que ainda não propagou. Omitir depois
  /// de um logout deixaria o id do usuário colado no aparelho para sempre.
  func testTrêsEstadosDoExternalUserId() {
    let amarrado = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: "u-9", saidaPendente: false, appVersion: nil)
    XCTAssertEqual(amarrado["external_user_id"] as? String, "u-9")

    let neutro = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    XCTAssertNil(neutro["external_user_id"], "ausente: o servidor não mexe")

    let saida = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: true, appVersion: nil)
    XCTAssertTrue(saida["external_user_id"] is NSNull, "null explícito: o servidor limpa")
  }

  /// R5: o hash é determinístico — dicionário Swift não tem ordem de inserção,
  /// e um hash que dependesse dela faria o app re-registrar ao acaso a cada
  /// abertura, quebrando a promessa de leveza do contrato.
  func testHashÉDeterminístico() {
    let a = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    var b: [String: Any] = [:] // construído em outra ordem, mesmos valores
    b["sdk_versao"] = a["sdk_versao"]
    b["app_id"] = a["app_id"]
    b["timezone"] = a["timezone"]
    b["identifier"] = a["identifier"]
    b["transporte"] = a["transporte"]
    b["device_type"] = a["device_type"]
    b["device_model"] = a["device_model"]
    b["device_os"] = a["device_os"]
    b["fabricante"] = a["fabricante"]
    b["language"] = a["language"]
    XCTAssertEqual(PushMesh.hashDoPayload(a), PushMesh.hashDoPayload(b))
    // E de novo a montagem, chamada duas vezes: mesma resposta.
    let c = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    XCTAssertEqual(PushMesh.hashDoPayload(a), PushMesh.hashDoPayload(c))
  }

  /// R6: o hash muda quando o ESSENCIAL muda — token rodou, usuário entrou,
  /// versão do app subiu. É o gatilho do re-registro.
  func testHashMudaQuandoOEssencialMuda() {
    let base = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    let comTokenNovo = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok-2", usuarioExterno: nil, saidaPendente: false, appVersion: nil)
    let comUsuario = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: "u-1", saidaPendente: false, appVersion: nil)
    let comVersão = PushMesh.montarPayloadDeRegistro(
      appId: "app", token: "tok", usuarioExterno: nil, saidaPendente: false, appVersion: "2.0.0")
    let hashes = [
      PushMesh.hashDoPayload(base), PushMesh.hashDoPayload(comTokenNovo),
      PushMesh.hashDoPayload(comUsuario), PushMesh.hashDoPayload(comVersão),
    ]
    XCTAssertEqual(Set(hashes).count, 4, "cada mudança essencial muda o hash")
  }
}

/// Peças pequenas, cada uma com um defeito que já existiu na história do projeto.
final class PecasTests: XCTestCase {

  /// A1: o byte ZERO do token não pode sumir — implementação ingênua de hex
  /// perde os zeros à esquerda e o token deixa de ser o token.
  func testTokenEmHexComByteZero() {
    XCTAssertEqual(Apns.compartilhado.tokenEmHex(Data([0x00, 0x0a, 0xff])), "000aff")
    XCTAssertEqual(Apns.compartilhado.tokenEmHex(Data([])), "")
    XCTAssertEqual(Apns.compartilhado.tokenEmHex(Data([0xff])), "ff")
  }

  /// A2: as chaves de armazenamento são AS MESMAS do SDK de JS (storage.ts) —
  /// é o que faz o app que migra de RN para nativo manter o mesmo player_id.
  /// `pm:fila` é a única própria: o formato do item difere do `pm:queue` do JS.
  func testChavesSãoAsMesmasDoSdkDeJS() {
    XCTAssertEqual(Chave.token.rawValue, "pm:token")
    XCTAssertEqual(Chave.playerId.rawValue, "pm:player_id")
    XCTAssertEqual(Chave.regHash.rawValue, "pm:reg_hash")
    XCTAssertEqual(Chave.transporte.rawValue, "pm:transporte")
    XCTAssertEqual(Chave.tiposNotificacao.rawValue, "pm:notif_types")
    XCTAssertEqual(Chave.usuarioExterno.rawValue, "pm:external_user_id")
    XCTAssertEqual(Chave.sessoes.rawValue, "pm:sessoes")
    XCTAssertEqual(Chave.lruRecibos.rawValue, "pm:receipt_lru")
    XCTAssertEqual(Chave.fila.rawValue, "pm:fila")
    XCTAssertEqual(Chave.saidaPendente.rawValue, "pm:logout_pendente")
  }

  /// A2-b: gravar pelo `Armazenamento` sem prefixo escreve NAS CHAVES CRUAS —
  /// sem prefixo escondido, sem suíte extra. É a continuidade da migração.
  func testArmazenamentoEscreveNasChavesCruas() {
    let suite = "pm-teste-" + UUID().uuidString
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    let armazenamento = Armazenamento(defaults: defaults)
    armazenamento.guardar("p-1", em: .playerId)
    armazenamento.guardar(3, em: .sessoes)
    XCTAssertEqual(defaults.string(forKey: "pm:player_id"), "p-1")
    XCTAssertEqual(defaults.integer(forKey: "pm:sessoes"), 3)
    // E o inverso: valor escrito pelo SDK de JS é lido pelo Swift.
    defaults.set("apns", forKey: "pm:transporte")
    XCTAssertEqual(armazenamento.texto(.transporte), "apns")
  }

  /// Round-trip do JSON heterogêneo — bool não vira número, número inteiro
  /// não vira quebrado, nulo sobrevive.
  func testCodavelQualquerRoundTrip() throws {
    let original: [String: CodavelQualquer] = [
      "texto": .texto("a"), "numero": .numero(7), "quebrado": .numero(1.5),
      "logico": .logico(true), "nulo": .nulo,
    ]
    let dados = try JSONEncoder().encode(original)
    let lido = try JSONDecoder().decode([String: CodavelQualquer].self, from: dados)
    XCTAssertEqual(lido, original)
    XCTAssertEqual(lido["numero"]?.valor as? Int, 7)
    XCTAssertEqual(lido["quebrado"]?.valor as? Double, 1.5)
    XCTAssertEqual(lido["logico"]?.valor as? Bool, true)
    XCTAssertNil(lido["nulo"]?.valor)
  }
}
