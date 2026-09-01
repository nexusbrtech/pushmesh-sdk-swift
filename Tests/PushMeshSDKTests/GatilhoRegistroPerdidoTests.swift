import Foundation
import XCTest

@testable import PushMeshSDK

/**
 O gatilho da cura do registro perdido (espelho do `registroPerdido` do JS).

 O cenário real, medido em 01/09/2026: o painel apagou a audiência; o aparelho
 instalado ficou com `playerId` + `regHash` em cache dizendo "nada mudou" e
 virou ÓRFÃO SILENCIOSO — recibo recusado com 404, e nenhum re-registro nunca.

 A cura em si (esquecer o cache e registrar de novo) mora no `PushMesh` e é
 estado global de propósito; o que se trava AQUI é o GATILHO da `Rede`: 404 em
 `/receipts` ou `/players/{id}` dispara `aoPerderRegistro` — e nada mais
 dispara. Um gatilho frouxo (qualquer 404) viraria rajada de re-registros para
 notificação velha; um gatilho surdo deixa o órfão para sempre.
 */
final class GatilhoRegistroPerdidoTests: CasoComRede {

  private func esperaGatilho() -> (XCTestExpectation, () -> [String]) {
    let exp = expectation(description: "aoPerderRegistro")
    exp.assertForOverFulfill = false
    var origens: [String] = []
    let trava = NSLock()
    rede.aoPerderRegistro = { origem in
      trava.lock()
      origens.append(origem)
      trava.unlock()
      exp.fulfill()
    }
    return (exp, { trava.lock(); defer { trava.unlock() }; return origens })
  }

  /// 404 no recibo (envio direto) dispara a cura com o caminho como origem.
  func testRecibo404DisparaOGatilho() async {
    let (exp, origens) = esperaGatilho()
    programar(.resposta(status: 404))

    let aceito = await rede.enviarOuGuardar(
      "POST", "/api/v1/receipts", ["player_id": "morto"])

    await fulfillment(of: [exp], timeout: 2)
    XCTAssertFalse(aceito, "404 continua descartando o recibo — a cura é do REGISTRO")
    XCTAssertEqual(origens(), ["/api/v1/receipts"])
  }

  /// 404 no PUT do player (login/permissão depois da limpeza) também dispara.
  func testPutDePlayer404DisparaOGatilho() async {
    let (exp, origens) = esperaGatilho()
    programar(.resposta(status: 404))

    _ = await rede.enviarOuGuardar(
      "PUT", "/api/v1/players/p-apagado", ["external_user_id": "u"])

    await fulfillment(of: [exp], timeout: 2)
    XCTAssertEqual(origens(), ["/api/v1/players/p-apagado"])
  }

  /// 404 vindo do REENVIO da fila (o flush do foreground) também cura — é o
  /// caminho do aparelho que estava offline quando a audiência foi apagada.
  func testFlush404DisparaOGatilho() async {
    programarDecisor { _ in .redeFora }
    _ = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["rcpt": "p"])

    let (exp, origens) = esperaGatilho()
    programar(.resposta(status: 404))
    relogio.avancar(3600)
    await rede.esvaziar(resolvendoPlayerId: "p-apagado")

    await fulfillment(of: [exp], timeout: 2)
    XCTAssertEqual(origens(), ["/api/v1/receipts"])
  }

  /// 400 é payload inválido, não aparelho esquecido — a cura NÃO dispara.
  func testQuatrocentosNaoDispara() async {
    var disparou = false
    rede.aoPerderRegistro = { _ in disparou = true }
    programar(.resposta(status: 400))

    _ = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["rcpt": "p"])

    XCTAssertFalse(disparou, "400 não pode virar re-registro — o payload é que está errado")
  }

  /// 404 fora dos dois caminhos (rota qualquer) não é sinal de player apagado.
  func testQuatrocentosEQuatroDeOutraRotaNaoDispara() async {
    var disparou = false
    rede.aoPerderRegistro = { _ in disparou = true }
    programar(.resposta(status: 404))

    _ = await rede.enviarOuGuardar("POST", "/api/v1/outra_coisa", ["x": "y"])

    XCTAssertFalse(disparou)
  }
}
