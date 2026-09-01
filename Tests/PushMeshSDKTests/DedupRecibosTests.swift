import Foundation
import XCTest
@testable import PushMeshSDK

/**
 Dedup LRU-64 do recibo. As duas leis testadas aqui:

 1. A ORDEM É LEI: o "já visto" só é marcado DEPOIS do aceite — marcar antes
    matava o recibo para sempre (um 5xx no primeiro envio e a reentrega do
    APNs batia no dedup e ia embora calada).
 2. Entrega e clique são fatos DISTINTOS da mesma notificação: chave só-id
    faria o clique bater no "já visto" e o painel mostraria zero clique.
 */
final class DedupRecibosTests: CasoComRede {
  private var recibos: Recibos!

  override func setUp() {
    super.setUp()
    recibos = Recibos(rede: rede, armazenamento: armazenamento)
  }

  /// D1: a reentrega do APNs não duplica recibo — a segunda passada é silêncio.
  func testReentregaNãoDuplica() async {
    programar()
    let primeira = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                        appId: "app", playerId: "p-1")
    let segunda = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                       appId: "app", playerId: "p-1")
    XCTAssertTrue(primeira)
    XCTAssertFalse(segunda, "o já-visto engole a reentrega")
    XCTAssertEqual(registroDePedidos.quantidade, 1)
  }

  /// D2: entrega e clique da MESMA notificação são dois fatos — a chave do
  /// clique é `<id>#clique`, e o `evento` viaja certo no corpo.
  func testEntregaECliqueSãoFatosDistintos() async {
    programar()
    _ = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                             appId: "app", playerId: "p-1")
    let clique = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .clique,
                                      appId: "app", playerId: "p-1")
    XCTAssertTrue(clique, "o clique não pode bater no já-visto da entrega")
    XCTAssertEqual(registroDePedidos.quantidade, 2)
    XCTAssertEqual(registroDePedidos.todos[1].corpo["evento"] as? String, "clique")
  }

  /// D3: guardado conta como aceite — a rede caiu, o recibo foi para a fila, o
  /// dedup marca. A reentrega não reenvia; quem entrega é a fila.
  func testGuardadoContaComoAceitoEMarcaOVisto() async {
    programar(.redeFora)
    let aceito = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                      appId: "app", playerId: "p-1")
    XCTAssertTrue(aceito)
    XCTAssertEqual(rede.pendentes, 1, "o recibo está na fila")
    XCTAssertEqual(registroDePedidos.quantidade, 1, "uma ida à rede, que caiu")
    let reentrega = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                         appId: "app", playerId: "p-1")
    XCTAssertFalse(reentrega, "a fila já tem esse recibo; não duplica")
    XCTAssertEqual(registroDePedidos.quantidade, 1, "a reentrega não gera nova ida")
    XCTAssertEqual(rede.pendentes, 1)
  }

  /// D4: 4xx NÃO marca o visto — a ordem é lei. Se o servidor recusou em
  /// definitivo, a reentrega ganha uma nova chance em vez de morrer no dedup.
  func testErro4xxNãoMarcaOVisto() async {
    programar(.resposta(status: 400), .resposta(status: 200))
    let primeira = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                        appId: "app", playerId: "p-1")
    XCTAssertFalse(primeira)
    let segunda = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                       appId: "app", playerId: "p-1")
    XCTAssertTrue(segunda, "não marcado como visto: tenta de novo")
    XCTAssertEqual(registroDePedidos.quantidade, 2)
  }

  /// D5: a janela é 64 e quem sai é o MAIS ANTIGO. Depois da 65ª notificação,
  /// o id 1 volta a poder enviar — e o id 3, que continua na janela, não.
  func testJanelaDeSessentaEQuatroEvictaOMaisAntigo() async {
    programar()
    for i in 1...65 {
      _ = await recibos.enviar(notificacao: "n-\(i)", prova: "p", evento: .recebido,
                               appId: "app", playerId: "p-1")
    }
    XCTAssertEqual(registroDePedidos.quantidade, 65)
    XCTAssertEqual(armazenamento.lista(.lruRecibos).count, 64)
    XCTAssertEqual(armazenamento.lista(.lruRecibos).first, "n-2", "o n-1 foi evictado")
    // O evictado volta a enviar; o que continua na janela, não.
    _ = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                             appId: "app", playerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 66, "o id que saiu da janela reenvia")
    _ = await recibos.enviar(notificacao: "n-3", prova: "p", evento: .recebido,
                             appId: "app", playerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 66, "o id dentro da janela segue dedupado")
  }

  /// D6: push de outra origem (sem `pm_msg_id`/`pm_rcpt`) é silêncio — o app
  /// host pode ter outro SDK de push no mesmo aparelho.
  func testPushDeOutraOrigemÉSilêncio() async {
    programar()
    let nosso = await recibos.processar(recibo("n-1"), appId: "app", playerId: "p-1")
    let alheio = await recibos.processar(["alert": "outra coisa", "outro_sdk": true],
                                         appId: "app", playerId: "p-1")
    XCTAssertTrue(nosso)
    XCTAssertFalse(alheio)
    XCTAssertEqual(registroDePedidos.quantidade, 1)
  }

  /// D7: o contrato do corpo ecoado — o SDK devolve a prova EXATAMENTE como
  /// veio no payload. Quem constrói a prova é o servidor; o SDK só ecoa.
  func testContratoDoCorpoEcoado() async {
    programar()
    _ = await recibos.processar(recibo("n-7"), appId: "app", playerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 1)
    let corpo = registroDePedidos.todos[0].corpo
    XCTAssertEqual(corpo["app_id"] as? String, "app")
    XCTAssertEqual(corpo["notification_id"] as? String, "n-7")
    XCTAssertEqual(corpo["rcpt"] as? String, "prova-de-n-7", "a prova viaja intacta")
    XCTAssertEqual(corpo["evento"] as? String, "recebido")
    XCTAssertEqual(corpo["player_id"] as? String, "p-1")
  }

  /// Sem registro ainda, o recibo vai para a FILA (não para a rede): o backend
  /// exige player_id e responde 400 — ir à rede seria perder o recibo do
  /// onboarding na hora. Com o player resolvido depois, ele sai inteiro.
  func testReciboSemRegistroVaiParaAFilaENãoParaARede() async {
    programar(.resposta(status: 400)) // o que o backend real responde sem player_id
    let aceito = await recibos.enviar(notificacao: "n-1", prova: "p", evento: .recebido,
                                      appId: "app", playerId: nil)
    XCTAssertTrue(aceito, "guardado = aceito; o dedup marca")
    XCTAssertEqual(registroDePedidos.quantidade, 0, "ninguém foi à rede sem player_id")
    XCTAssertEqual(rede.pendentes, 1)
    XCTAssertTrue(filaInterna()[0].corpo["player_id"] == .nulo)
    // O registro chega; a fila resolve e entrega.
    programar()
    relogio.avancar(400)
    await rede.esvaziar(resolvendoPlayerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 1)
    XCTAssertEqual(registroDePedidos.todos[0].corpo["player_id"] as? String, "p-1")
    XCTAssertEqual(rede.pendentes, 0)
  }
}
