import Foundation
import Network
import XCTest
@testable import PushMeshSDK

/** O que o servidor falso recebeu, já decodificado. */
struct PedidoRecebido {
  let metodo: String
  let caminho: String
  let corpo: [String: Any]
}

/** O que o servidor falso responderá ao pedido — ou a ausência de rede. */
enum Desfecho {
  case resposta(status: Int, corpo: [String: Any] = [:], headers: [String: String] = [:])
  case redeFora
}

/**
 Servidor HTTP falso via `URLProtocol`.

 O roteio é por host ÚNICO POR TESTE (a `baseUrl` que a base gera com UUID), então
 a suíte pode rodar em paralelo sem um teste responder o pedido do outro.

 Importante para a lição do projeto: este servidor imita o backend REAL nas
 fronteiras que importam — 400 para recibo sem `player_id`, `Retry-After` no
 429/503. Um servidor falso que respondesse 200 para qualquer coisa seria o mock
 codificando a crença que o teste deveria derrubar.
 */
final class ServidorFalso: URLProtocol {
  private static let trava = NSLock()
  private static var decisores: [String: (PedidoRecebido) -> Desfecho] = [:]

  static func atender(baseUrl: String, decidir: @escaping (PedidoRecebido) -> Desfecho) {
    guard let host = URL(string: baseUrl)?.host else { return }
    trava.lock(); defer { trava.unlock() }
    decisores[host] = decidir
  }

  static func esquecer(baseUrl: String) {
    guard let host = URL(string: baseUrl)?.host else { return }
    trava.lock(); defer { trava.unlock() }
    decisores.removeValue(forKey: host)
  }

  static func novaSessao() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [ServidorFalso.self]
    return URLSession(configuration: cfg)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let pedido = PedidoRecebido(
      metodo: request.httpMethod ?? "",
      caminho: url.path,
      corpo: ServidorFalso.dicionarioDoCorpo(ServidorFalso.dadosDoCorpo(request)))
    let decidir: ((PedidoRecebido) -> Desfecho)?
    ServidorFalso.trava.lock()
    decidir = ServidorFalso.decisores[url.host ?? ""]
    ServidorFalso.trava.unlock()
    guard let decidir else {
      // Sem rota registrada: host desconhecido é o mesmo que rede fora.
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    switch decidir(pedido) {
    case .redeFora:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case .resposta(let status, let corpo, let headers):
      let dados = (try? JSONSerialization.data(withJSONObject: corpo)) ?? Data()
      guard let resposta = HTTPURLResponse(url: url, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: resposta, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: dados)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  /// Em `URLProtocol` o corpo vira stream — ler byte a byte.
  private static func dadosDoCorpo(_ request: URLRequest) -> Data? {
    if let dados = request.httpBody { return dados }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var dados = Data()
    let tamanho = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: tamanho)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let lidos = stream.read(buffer, maxLength: tamanho)
      if lidos <= 0 { break }
      dados.append(buffer, count: lidos)
    }
    return dados
  }

  private static func dicionarioDoCorpo(_ dados: Data?) -> [String: Any] {
    guard let dados, let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any] else {
      return [:]
    }
    return obj
  }
}

/** Registro thread-safe do que chegou ao servidor falso. */
final class RegistroDePedidos {
  private let trava = NSLock()
  private var itens: [PedidoRecebido] = []
  func anotar(_ pedido: PedidoRecebido) {
    trava.lock(); defer { trava.unlock() }
    itens.append(pedido)
  }
  var todos: [PedidoRecebido] {
    trava.lock(); defer { trava.unlock() }
    return itens
  }
  var quantidade: Int { todos.count }
}

/** Relógio e jitter determinísticos, injetados na Rede. */
final class RelogioDeTeste {
  var instante = Date(timeIntervalSince1970: 1_751_000_000)
  var segundos: TimeInterval { instante.timeIntervalSince1970 }
  func avancar(_ s: TimeInterval) { instante = instante.addingTimeInterval(s) }
}

final class JitterDeTeste {
  /// Fração do teto de jitter a aplicar (0…1). 0 = sem jitter.
  var valor: Double = 0
}

/**
 Base dos casos de teste: servidor falso roteado, armazenamento em suíte
 descartável de UserDefaults, relógio e jitter determinísticos.
 */
class CasoComRede: XCTestCase {
  var registroDePedidos: RegistroDePedidos!
  var relogio: RelogioDeTeste!
  var jitter: JitterDeTeste!
  var armazenamento: Armazenamento!
  var rede: Rede!
  var baseUrl: String!
  private var suite: String!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    suite = "pm-teste-" + UUID().uuidString
    baseUrl = "http://pm-" + UUID().uuidString
    registroDePedidos = RegistroDePedidos()
    relogio = RelogioDeTeste()
    jitter = JitterDeTeste()
    armazenamento = Armazenamento(defaults: UserDefaults(suiteName: suite)!)
    rede = Rede(baseUrl: baseUrl, armazenamento: armazenamento,
                sessao: ServidorFalso.novaSessao(),
                agora: { [relogio] in relogio.instante },
                jitter: { [jitter] in jitter.valor })
  }

  override func tearDown() {
    ServidorFalso.esquecer(baseUrl: baseUrl)
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  /** Programar uma fila de desfechos; esgotada, o servidor responde 200. */
  func programar(_ desfechos: Desfecho...) {
    var pendentes = desfechos
    let registro = registroDePedidos!
    ServidorFalso.atender(baseUrl: baseUrl) { pedido in
      registro.anotar(pedido)
      if pendentes.isEmpty { return .resposta(status: 200) }
      return pendentes.removeFirst()
    }
  }

  /** Programar por decisão, pedido a pedido — para respostas que dependem do corpo. */
  func programarDecisor(_ decidir: @escaping (PedidoRecebido) -> Desfecho) {
    let registro = registroDePedidos!
    ServidorFalso.atender(baseUrl: baseUrl) { pedido in
      registro.anotar(pedido)
      return decidir(pedido)
    }
  }

  /// A fila interna, decodificada — é daqui que se lê `tentativas` e `naoAntesDe`.
  func filaInterna() -> [PedidoGuardado] {
    guard let texto = armazenamento.texto(.fila),
          let dados = texto.data(using: .utf8),
          let itens = try? JSONDecoder().decode([PedidoGuardado].self, from: dados) else { return [] }
    return itens
  }

  /// Um recibo como o que o disparo embute no payload do push.
  func recibo(_ msgId: String) -> [AnyHashable: Any] {
    ["pm_msg_id": msgId, "pm_rcpt": "prova-de-\(msgId)"]
  }
}

/**
 Servidor TCP REAL em loopback, para provar concorrência.

 Descoberta desta suíte: o `URLSession` com `URLProtocol` custom SERIALIZA os
 requests — 5 envios concorrentes medem pico 1. Qualquer afirmação sobre
 "quantos pedidos estão em voo" feita com URLProtocol é o instrumento mentindo,
 não o SDK. Este servidor aceita conexões de verdade: conexão aberta e ainda
 não respondida É pedido em voo, e o pico se mede contando conexões.
 */
final class ServidorLocal {
  private var listener: NWListener?
  private let fila = DispatchQueue(label: "io.pushmesh.servidor-local")
  private let trava = NSLock()
  private let liberar = DispatchSemaphore(value: 0)
  /// Quantas conexões iniciais ficam presas até o teste liberar — o necessário
  /// para o pico ser observável. As demais são respondidas na hora.
  private var _presasRestantes: Int
  private var _abertas = 0
  private var _pico = 0
  private var _pedidos: [(metodo: String, caminho: String)] = []

  init(presas: Int = 5) {
    _presasRestantes = presas
  }

  var porta: UInt16 { listener?.port?.rawValue ?? 0 }
  var pico: Int { trava.lock(); defer { trava.unlock() }; return _pico }
  var abertas: Int { trava.lock(); defer { trava.unlock() }; return _abertas }
  var pedidos: [(metodo: String, caminho: String)] {
    trava.lock(); defer { trava.unlock() }
    return _pedidos
  }

  func iniciar() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // Só loopback: servidor de teste não escuta na rede.
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: params)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] conexao in
      guard let self else { conexao.cancel(); return }
      self.conexaoAbriu()
      conexao.stateUpdateHandler = { estado in
        switch estado {
        case .cancelled, .failed: self.conexaoFechou()
        default: break
        }
      }
      conexao.start(queue: self.fila)
      self.lerRequest(conexao, acumulado: Data())
    }
    listener.start(queue: fila)
    // Espera a porta ser escolhida.
    let prazo = Date().addingTimeInterval(5)
    while porta == 0 && Date() < prazo { Thread.sleep(forTimeInterval: 0.01) }
    if porta == 0 { throw NSError(domain: "servidor-local", code: 1) }
  }

  /// Solta as conexões presas.
  func liberarPresas() {
    trava.lock(); let n = _presasRestantes; _presasRestantes = 0; trava.unlock()
    for _ in 0..<n { liberar.signal() }
  }

  func parar() {
    liberarPresas()
    listener?.cancel()
  }

  private func prenderSeForDasPrimeiras() {
    trava.lock()
    let prender = _presasRestantes > 0
    if prender { _presasRestantes -= 1 }
    trava.unlock()
    if prender { liberar.wait() }
  }

  /**
   Leitura de request HTTP em loop — `receiveMessage` NÃO serve aqui: ele só
   entrega quando o peer fecha a conexão, e um cliente HTTP saudável mantém a
   conexão aberta ESPERANDO a resposta. Medido na prática: o receiveMessage
   disparava no instante do TIMEOUT do cliente, e a resposta ia para um morto.
   */
  private func lerRequest(_ conexao: NWConnection, acumulado: Data) {
    conexao.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { dados, _, fim, erro in
      var acumulado = acumulado
      if let dados { acumulado.append(dados) }
      if ServidorLocal.requestCompleto(acumulado) {
        self.anotar(acumulado)
        // As primeiras N esperam a ordem do teste — é o que torna o pico
        // observável. O resto é respondido na hora.
        self.prenderSeForDasPrimeiras()
        let resposta = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        conexao.send(content: resposta.data(using: .utf8), completion: .contentProcessed { _ in
          // Sem cancel forçado: `Connection: close` faz o cliente fechar, e o
          // estado da conexão é quem decrementa `abertas`.
        })
        return
      }
      if erro == nil && !fim {
        self.lerRequest(conexao, acumulado: acumulado)
        return
      }
      conexao.cancel() // fechou sem request completo
    }
  }

  /// Fim de cabeçalho + Content-Length do corpo satisfeito.
  private static func requestCompleto(_ dados: Data) -> Bool {
    guard let faixa = dados.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return false }
    let cabecalho = String(data: dados[..<faixa.lowerBound], encoding: .utf8) ?? ""
    let corpoEsperado = cabecalho
      .components(separatedBy: "\r\n")
      .compactMap { linha -> Int? in
        let partes = linha.split(separator: ":", maxSplits: 1)
        guard partes.count == 2, partes[0].lowercased() == "content-length" else { return nil }
        return Int(partes[1].trimmingCharacters(in: .whitespaces))
      }
      .first ?? 0
    return dados.count - faixa.upperBound >= corpoEsperado
  }

  private func conexaoAbriu() {
    trava.lock(); defer { trava.unlock() }
    _abertas += 1
    _pico = max(_pico, _abertas)
  }

  private func conexaoFechou() {
    trava.lock(); defer { trava.unlock() }
    _abertas = max(0, _abertas - 1)
  }

  private func anotar(_ dados: Data?) {
    guard let primeira = dados.flatMap({ String(data: $0, encoding: .utf8)?
      .split(separator: "\r\n").first }) else { return }
    let partes = primeira.split(separator: " ")
    guard partes.count >= 2 else { return }
    trava.lock(); defer { trava.unlock() }
    _pedidos.append((metodo: String(partes[0]), caminho: String(partes[1])))
  }
}
