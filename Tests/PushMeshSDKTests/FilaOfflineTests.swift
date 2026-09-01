import Foundation
import XCTest
@testable import PushMeshSDK

/**
 Fila offline: quem guarda, quem descarta, quem gasta tentativa.

 Cada caso abaixo existe para derrubar uma crença específica — o número no
 comentário remete ao desenho aprovado. O orçamento inteiro (backoff, jitter,
 Retry-After, concorrência) é o mesmo do SDK de JS (`sdk/src/queue.ts`), e os
 casos F11/F13/F15 são as provas de que o porte NÃO perdeu o motivo de novo.
 */
final class FilaOfflineTests: CasoComRede {

  // MARK: - Quem guarda (F1–F4)

  /// F1: 2xx entrega e não deixa rastro na fila.
  func testRespostaDeSucessoNãoDeixaFila() async {
    programar()
    let aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertTrue(aceito)
    XCTAssertEqual(rede.pendentes, 0)
    XCTAssertEqual(registroDePedidos.quantidade, 1)
  }

  /// F2: rede fora guarda e devolve `true` — "aceito" é entregue OU guardado.
  /// É nesse contrato que o dedup do recibo se apoia (D3).
  func testRedeForaGuardaEContaComoAceito() async {
    programar(.redeFora)
    let aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertTrue(aceito)
    XCTAssertEqual(rede.pendentes, 1)
  }

  /// F3: 4xx descarta NA ORIGEM — retry cego não corrige payload errado.
  func testErro4xxDescartaNaOrigem() async {
    programar(.resposta(status: 400, corpo: ["erro": "inválido"]))
    let aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertFalse(aceito)
    XCTAssertEqual(rede.pendentes, 0)
  }

  /// F4: 5xx guarda — servidor fora do ar no pico de campanha não é payload errado.
  func testErro5xxGuardaParaRetentar() async {
    programar(.resposta(status: 503))
    let aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertTrue(aceito)
    XCTAssertEqual(rede.pendentes, 1)
  }

  // MARK: - Teto e descarte FIFO (F5)

  /// F5: acima de 500, quem sai é o MAIS ANTIGO — o recibo de agora vale mais
  /// que o de três dias atrás. Prova FIFO: o primeiro da fila resultante é o
  /// item 2, e o item 501 continua presente.
  func testTetoDeQuinhentosDescartaOMaisAntigo() async {
    for i in 1...501 {
      rede.guardar("POST", "/api/v1/receipts", ["i": i])
    }
    XCTAssertEqual(rede.pendentes, 500)
    let fila = filaInterna()
    XCTAssertEqual(fila.first?.corpo["i"]?.valor as? Int, 2)
    XCTAssertEqual(fila.last?.corpo["i"]?.valor as? Int, 501)
    XCTAssertEqual(fila.first?.corpo["i"]?.valor as? Int, 2)
  }

  // MARK: - Esvaziar (F6–F9)

  /// F6: fila entregue por completo, com o corpo ÍNTEGRO — string, inteiro,
  /// booleano e nulo sobrevivem ao round-trip do JSON heterogêneo.
  func testEsvaziarEntregaTudoComCorpoIntegro() async {
    programar()
    rede.guardar("POST", "/api/v1/receipts", [
      "app_id": "app-1", "notification_id": "n-1", "rcpt": "prova",
      "evento": "recebido", "player_id": "p-1", "numero": 7,
      "logico": true, "ausente": NSNull(),
    ])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 0)
    XCTAssertEqual(registroDePedidos.quantidade, 1)
    let corpo = registroDePedidos.todos[0].corpo
    XCTAssertEqual(corpo["app_id"] as? String, "app-1")
    XCTAssertEqual(corpo["notification_id"] as? String, "n-1")
    XCTAssertEqual(corpo["numero"] as? Int, 7)
    XCTAssertEqual(corpo["logico"] as? Bool, true)
    XCTAssertTrue(corpo["ausente"] is NSNull)
  }

  /// F7: falha de rede no reenvio devolve o item com UMA tentativa gasta —
  /// só a ida à rede que falhou gasta orçamento.
  func testFalhaDeRedeNoReenvioGastaUmaTentativa() async {
    programar(.redeFora)
    rede.guardar("POST", "/api/v1/receipts", ["app_id": "a"])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 1)
    XCTAssertEqual(filaInterna()[0].tentativas, 1)
  }

  /// F8: o item desiste na DÉCIMA falha — nem nove, nem onze. Entre as
  /// tentativas o relógio avança o bastante para o backoff vencer.
  func testItemDesisteNaDecimaTentativa() async {
    programarDecisor { _ in .redeFora } // TODAS as idas falham — nunca 200
    rede.guardar("POST", "/api/v1/receipts", ["app_id": "a"])
    for rodada in 1...9 {
      await rede.esvaziar(resolvendoPlayerId: nil)
      XCTAssertEqual(rede.pendentes, 1, "o item devia sobreviver após a \(rodada)ª tentativa")
      relogio.avancar(400) // backoff nunca passa de 300s + 1s de jitter
    }
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 0, "na décima tentativa o item desiste")
  }

  /// F9: 4xx no REENVIO também descarta imediatamente — distinto de F3, o item
  /// já estava guardado e ainda assim não espera as 10 tentativas.
  func testErro4xxNoReenvioDescartaImediatamente() async {
    programar(.resposta(status: 404))
    rede.guardar("POST", "/api/v1/receipts", ["app_id": "a"])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 0)
    XCTAssertEqual(filaInterna().count, 0)
  }

  // MARK: - Registro e player_id (F10, F11, F14)

  /// F10: recibo guardado com `player_id` NULO (push chegou antes do POST
  /// /players responder) é resolvido NA HORA do envio — o servidor recebe o id.
  func testPlayerIdNuloÉResolvidoNaHoraDoEnvio() async {
    programar()
    rede.guardar("POST", "/api/v1/receipts", [
      "app_id": "a", "notification_id": "n", "player_id": NSNull(),
    ])
    await rede.esvaziar(resolvendoPlayerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 1)
    XCTAssertEqual(registroDePedidos.todos[0].corpo["player_id"] as? String, "p-1")
    XCTAssertEqual(rede.pendentes, 0)
  }

  /// F11 — a prova da frase: ESPERAR REGISTRO NÃO GASTA TENTATIVA. Recibo sem
  /// player_id, esvaziares repetidos SEM registro: zero idas à rede, contador
  /// intacto. É o recibo do onboarding — o mais valioso — que está em jogo.
  /// O servidor aqui está ATIVO e respondendo 400 (o que o backend real faz com
  /// recibo sem player_id): se o SDK fosse à rede, o 4xx descartaria o recibo.
  func testEsperaDeRegistroNãoGastaTentativa() async {
    programar(.resposta(status: 400)) // backend real: player_id é obrigatório
    rede.guardar("POST", "/api/v1/receipts", [
      "app_id": "a", "notification_id": "n", "player_id": NSNull(),
    ])
    for _ in 1...3 {
      await rede.esvaziar(resolvendoPlayerId: nil)
      relogio.avancar(400) // vence o atraso do adiamento
    }
    XCTAssertEqual(registroDePedidos.quantidade, 0, "esperar registro não pode ir à rede")
    XCTAssertEqual(rede.pendentes, 1, "o recibo continua na fila")
    XCTAssertEqual(filaInterna()[0].tentativas, 0, "e o orçamento de tentativas intacto")
    // O registro chega: o MESMO recibo sai com o id resolvido.
    programar()
    await rede.esvaziar(resolvendoPlayerId: "p-1")
    XCTAssertEqual(registroDePedidos.quantidade, 1)
    XCTAssertEqual(rede.pendentes, 0)
  }

  /// F14: PUT de permissão NÃO carrega `player_id` no corpo (o id mora no
  /// caminho). A espera do registro é só para o campo EXPLICITAMENTE nulo — um
  /// PUT não pode ficar preso para sempre à espera de um registro que não usa.
  func testPutSemPlayerIdNoCorpoNãoFicaPreso() async {
    programar()
    rede.guardar("PUT", "/api/v1/players/p-9", ["app_id": "a", "notification_types": 1])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(registroDePedidos.quantidade, 1, "o PUT sai mesmo sem registro")
    XCTAssertEqual(rede.pendentes, 0)
  }

  // MARK: - Concorrência do esvaziar (F12)

  /// F12: item que CHEGA durante o esvaziar não é sobrescrito pelo regravar
  /// final — o zerar-e-remesclar preserva quem entrou no meio da rede.
  func testItemQueChegaDuranteOEsvaziarNãoSePerde() async {
    let jaGuardou = NSLock()
    var guardou = false
    programarDecisor { [weak self] _ in
      // Quando o pedido do item antigo chega, um item NOVO entra na fila —
      // é exatamente o instante em que o esvaziar está com a fila zerada.
      jaGuardou.lock()
      if !guardou {
        guardou = true
        self?.rede.guardar("POST", "/api/v1/receipts", ["novo": true])
      }
      jaGuardou.unlock()
      return .redeFora
    }
    rede.guardar("POST", "/api/v1/receipts", ["antigo": true])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 2, "o antigo voltou e o novo não foi pisado")
  }

  // MARK: - 429 e Retry-After (F13, F15, F17)

  /// F13: 429 é "volta mais tarde", não "payload errado" — guarda na origem e
  /// retenta no reenvio, em vez de descartar o recibo.
  func test429ÉRetentávelENãoDescarta() async {
    programar(.resposta(status: 429, headers: ["Retry-After": "1"]))
    let aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertTrue(aceito)
    XCTAssertEqual(rede.pendentes, 1)
    programar(.resposta(status: 429, headers: ["Retry-After": "1"]))
    relogio.avancar(2)
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 1, "429 no reenvio devolve o item para a fila")
    XCTAssertEqual(filaInterna()[0].tentativas, 1)
  }

  /// F15: `Retry-After` é honrado ACIMA do backoff local — na origem e no
  /// reenvio. O item nasce/agenda para o instante que o SERVIDOR mandou, não
  /// para o que a nossa fórmula acharia melhor. Martelar quem pediu pausa é o
  /// contrário de fila educada.
  func testRetryAfterÉHonradoNaOrigemENoReenvio() async {
    programar(.resposta(status: 429, headers: ["Retry-After": "120"]))
    _ = await rede.enviarOuGuardar("POST", "/api/v1/receipts", ["app_id": "a"])
    XCTAssertEqual(filaInterna()[0].naoAntesDe, relogio.segundos + 120, accuracy: 0.001)
    XCTAssertEqual(registroDePedidos.quantidade, 1, "a ida que TOMOU o 429")
    // Antes de 120s: NÃO TENTA DE NOVO — nenhuma ida nova.
    relogio.avancar(119)
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(registroDePedidos.quantidade, 1, "ainda dentro do Retry-After não tenta")
    // Depois: tenta.
    relogio.avancar(2)
    programar(.resposta(status: 503, headers: ["Retry-After": "60"]))
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(filaInterna()[0].naoAntesDe, relogio.segundos + 60,
                   accuracy: 0.001, "no reenvio o Retry-After vence o backoff")
    XCTAssertEqual(filaInterna()[0].tentativas, 1)
  }

  /// F17: o parse do `Retry-After` — segundos ou data HTTP, teto de 30 min,
  /// piso 0, lixo ignorado. O teto existe para o item não virar zumbi.
  func testAnáliseDoRetryAfter() {
    let agora = Date(timeIntervalSince1970: 1_751_000_000)
    XCTAssertEqual(Rede.analisarRetryAfter("120", agora: agora), 120)
    XCTAssertEqual(Rede.analisarRetryAfter("  30 ", agora: agora), 30)
    XCTAssertEqual(Rede.analisarRetryAfter("3600", agora: agora), 1800, "teto de 30 min")
    XCTAssertEqual(Rede.analisarRetryAfter("-5", agora: agora), 0, "piso em zero")
    // Uma hora no futuro, além do teto: vira 30 min.
    let daquiUmaHora = agora.addingTimeInterval(3600)
    let formato = DateFormatter()
    formato.locale = Locale(identifier: "en_US_POSIX")
    formato.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    formato.timeZone = TimeZone(identifier: "GMT")
    let dataFutura = formato.string(from: daquiUmaHora)
    XCTAssertEqual(Rede.analisarRetryAfter(dataFutura, agora: agora), 1800)
    // Data no passado: pode já.
    let dataPassada = formato.string(from: agora.addingTimeInterval(-600))
    XCTAssertEqual(Rede.analisarRetryAfter(dataPassada, agora: agora), 0)
    // Lixo nas duas formas: header ignorado.
    XCTAssertNil(Rede.analisarRetryAfter("abc", agora: agora))
    XCTAssertNil(Rede.analisarRetryAfter(nil, agora: agora))
    XCTAssertNil(Rede.analisarRetryAfter("", agora: agora))
  }

  // MARK: - Backoff e jitter (F16)

  /// F16: base exponencial 1s, 2s, 4s… com teto de 5 min, MAIS jitter de até
  /// 1s. O jitter não é enfeite: sem ele, mil aparelhos voltando online juntos
  /// martelam o servidor no mesmo segundo.
  func testBackoffExponencialComTetoEJitter() {
    jitter.valor = 0
    XCTAssertEqual(rede.atrasoDeTentativa(0), 1)
    XCTAssertEqual(rede.atrasoDeTentativa(1), 2)
    XCTAssertEqual(rede.atrasoDeTentativa(2), 4)
    XCTAssertEqual(rede.atrasoDeTentativa(3), 8)
    XCTAssertEqual(rede.atrasoDeTentativa(9), 300, "512s capado no teto de 5 min")
    XCTAssertEqual(rede.atrasoDeTentativa(20), 300)
    jitter.valor = 1
    XCTAssertEqual(rede.atrasoDeTentativa(1), 3, accuracy: 0.000001, "2s de backoff + 1s de jitter")
    jitter.valor = 0.5
    XCTAssertEqual(rede.atrasoDeTentativa(1), 2.5, accuracy: 0.000001)
    jitter.valor = 1
    XCTAssertEqual(rede.atrasoDeTentativa(9), 301, accuracy: 0.000001, "jitter entra MESMO no teto")
  }

  /// F8-b: o item que falha por rede agenda a próxima tentativa com o backoff
  /// da tentativa que VAI vir — cresce a cada falha.
  func testBackoffCresceACadaFalha() async {
    programar(.redeFora, .redeFora)
    rede.guardar("POST", "/api/v1/receipts", ["app_id": "a"])
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(filaInterna()[0].naoAntesDe, relogio.segundos + 2, accuracy: 0.001)
    relogio.avancar(400)
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(filaInterna()[0].naoAntesDe, relogio.segundos + 4, accuracy: 0.001,
                   "segunda falha agenda 4s, não 2s de novo")
  }

  // MARK: - Lei 3: coalescing de escritas de estado

  /// Lei 3-a: PUT é escrita de ESTADO — a fila guarda só a MAIS NOVA de cada
  /// chave (recurso + campos). Reenviar PUT velho por cima de novo re-cola
  /// dado antigo no servidor (o CPF de quem já saiu).
  func testPutDeEstadoCoalesceNaFila() {
    rede.guardar("PUT", "/api/v1/players/p-1", ["app_id": "a", "notification_types": 1])
    relogio.avancar(1)
    rede.guardar("PUT", "/api/v1/players/p-1", ["app_id": "a", "notification_types": 0])
    XCTAssertEqual(rede.pendentes, 1, "a escrita velha virou lixo no guard")
    XCTAssertEqual(filaInterna()[0].corpo["notification_types"]?.valor as? Int, 0)
  }

  /// Lei 3-b: POST é FATO imutável — dois recibos nunca coalescem.
  func testPostNuncaCoalesce() {
    rede.guardar("POST", "/api/v1/receipts", ["notification_id": "n-1"])
    rede.guardar("POST", "/api/v1/receipts", ["notification_id": "n-2"])
    XCTAssertEqual(rede.pendentes, 2)
  }

  /// Lei 3-c — o filme completo: login cai na fila com rede fora; a rede volta
  /// e o LOGOUT entrega direto; o login VELHO da fila não pode mais subir —
  /// escrita entregue supersede retry mais antigo.
  func testLoginVelhoNãoVoltaDepoisDoLogoutEntregue() async {
    programarDecisor { [weak self] pedido in
      // O logout entrega na hora; o login velho NEM PODE aparecer depois.
      if pedido.corpo["external_user_id"] is NSNull { return .resposta(status: 200) }
      if let self, pedido.corpo["external_user_id"] != nil,
         filaInterna().isEmpty == false { return .resposta(status: 200) }
      return .redeFora // o login tenta ir direto e a rede "cai": vai para a fila
    }
    rede.guardar("PUT", "/api/v1/players/p-1", ["app_id": "a", "external_user_id": "cpf-1"])
    relogio.avancar(1)
    // O logout entrega DIRETO (rede boa para ele).
    _ = await rede.enviarOuGuardar("PUT", "/api/v1/players/p-1",
                                   ["app_id": "a", "external_user_id": NSNull()])
    XCTAssertEqual(rede.pendentes, 1, "o login velho segue na fila… por enquanto")
    relogio.avancar(400) // vence o atraso dele
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(rede.pendentes, 0, "superado pela entrega do logout: é lixo")
    let logins = registroDePedidos.todos.filter { pedido in
      (pedido.corpo["external_user_id"] as? String) == "cpf-1"
    }
    XCTAssertTrue(logins.isEmpty, "o CPF do login velho JAMAIS chega ao servidor")
  }

  // MARK: - Lei 1: o lote em voo sobrevive à morte no meio do esvaziar

  /// Lei 1-a: enquanto o esvaziar está NA REDE, o lote due vive em
  /// `pm:fila_em_voo`, não na fila — morrer aqui não o perde.
  func testLoteDueViveEmVooDuranteARede() async {
    let viuEmVoo = ContadorDeSinais()
    rede.guardar("POST", "/api/v1/receipts", ["app_id": "a"])
    programarDecisor { [weak self] _ in
      if self?.armazenamento.texto(.filaEmVoo) != nil { viuEmVoo.sinalizar() }
      return .redeFora
    }
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(viuEmVoo.vezes, 1, "o pedido saiu com o lote registrado em voo")
  }

  /// Lei 1-b: o lote órfão de um esvaziar que MORREU no meio (nunca regravou)
  /// é reabsorvido pelo próximo arranque e entregue — duplicata eventual é
  /// absorvida pelo servidor (pm:rcpt NX / PUT idempotente).
  func testLoteÓrfãoÉReabsorvidoEEntregue() async {
    programar()
    let orfao = PedidoGuardado(metodo: "POST", caminho: "/api/v1/receipts",
                               corpo: ["app_id": .texto("a"), "notification_id": .texto("n-x")])
    let dados = try! JSONEncoder().encode([orfao])
    armazenamento.guardar(String(data: dados, encoding: .utf8), em: .filaEmVoo)
    await rede.esvaziar(resolvendoPlayerId: nil)
    XCTAssertEqual(registroDePedidos.quantidade, 1, "o órfão foi entregue")
    XCTAssertEqual(rede.pendentes, 0)
    let sobrasEmVoo = armazenamento.texto(.filaEmVoo).flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode([PedidoGuardado].self, from: $0) } ?? []
    XCTAssertTrue(sobrasEmVoo.isEmpty, "em voo limpo no fim")
  }

  // MARK: - Concorrência máxima (F18)

  /// F18: no máximo 5 pedidos em voo no esvaziar — nunca uma rajada por
  /// aparelho. Prova sobre SERVIDOR TCP DE VERDADE em loopback: o URLProtocol
  /// do ferramental serializa os requests (pico 1 mesmo com 5 envios
  /// concorrentes — medido nesta suíte), então concorrência não se prova com
  /// ele. Aqui, conexão aberta e sem resposta é pedido em voo.
  func testNoMáximoCincoPedidosEmVooNoEsvaziar() async throws {
    let servidor = ServidorLocal()
    try servidor.iniciar()
    defer { servidor.parar() }
    rede = Rede(baseUrl: "http://127.0.0.1:\(servidor.porta)", armazenamento: armazenamento,
                sessao: URLSession(configuration: .ephemeral),
                agora: { [relogio] in relogio.instante },
                jitter: { [jitter] in jitter.valor })
    for i in 0..<20 {
      rede.guardar("POST", "/api/v1/receipts", ["i": i])
    }
    let tarefa = Task { await rede.esvaziar(resolvendoPlayerId: nil) }

    // Os 5 primeiros abrem conexão e ESPERAM resposta.
    let prazo = Date().addingTimeInterval(10)
    while servidor.pico < 5 && Date() < prazo {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(servidor.pico, 5, "os 5 primeiros chegam")
    // Tempo de sobra para um 6º errado aparecer — e não pode.
    try await Task.sleep(nanoseconds: 400_000_000)
    XCTAssertEqual(servidor.pico, 5, "o 6º pedido não pode entrar em voo")
    XCTAssertEqual(servidor.abertas, 5)

    servidor.liberarPresas()
    await tarefa.value
    // As anotações chegam um fôlego depois da última resposta.
    let prazoFinal = Date().addingTimeInterval(5)
    while servidor.pedidos.count < 20 && Date() < prazoFinal {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(servidor.pedidos.count, 20, "todos os 20 saem, de 5 em 5")
    XCTAssertEqual(rede.pendentes, 0)
  }
}

/** Contador simples de sinais, para a Lei 1. */
final class ContadorDeSinais {
  private let trava = NSLock()
  private var _vezes = 0
  var vezes: Int {
    trava.lock(); defer { trava.unlock() }
    return _vezes
  }
  func sinalizar() {
    trava.lock(); defer { trava.unlock() }
    _vezes += 1
  }
}
