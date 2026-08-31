import Foundation

/** Endereço oficial. Igual ao do SDK de JS — errar isto foi o defeito da 0.7.2. */
let baseUrlPadrao = "https://api.pushmesh.io"

/** Um pedido guardado para reenvio. */
struct PedidoGuardado: Codable {
  let metodo: String
  let caminho: String
  let corpo: [String: CodavelQualquer]
  var tentativas: Int
}

/**
 Caixa para JSON heterogêneo — `Codable` não engole `[String: Any]`, e o corpo do
 registro tem string, número, booleano e nulo misturados.
 */
enum CodavelQualquer: Codable, Equatable {
  case texto(String), numero(Double), logico(Bool), nulo

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .nulo }
    else if let v = try? c.decode(Bool.self) { self = .logico(v) }
    else if let v = try? c.decode(Double.self) { self = .numero(v) }
    else { self = .texto(try c.decode(String.self)) }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .texto(let v): try c.encode(v)
    case .numero(let v): try c.encode(v)
    case .logico(let v): try c.encode(v)
    case .nulo: try c.encodeNil()
    }
  }
  var valor: Any? {
    switch self {
    case .texto(let v): return v
    case .numero(let v): return v == v.rounded() ? Int(v) : v
    case .logico(let v): return v
    case .nulo: return nil
    }
  }
}

/**
 Cliente HTTP com fila offline.

 A fila existe porque a promessa central do produto é o RECIBO: perder um recibo
 por causa de um 5xx momentâneo é perder a prova de entrega — o número que nos
 separa do concorrente. Então falha de rede e 5xx guardam; 4xx descarta (pedido
 malformado não melhora com repetição).
 */
final class Rede {
  private let baseUrl: String
  private let armazenamento: Armazenamento
  private let sessao: URLSession
  private let fila = DispatchQueue(label: "io.pushmesh.rede")
  /// Teto da fila. Acima disso descarta o MAIS ANTIGO — o recibo de agora vale
  /// mais que o de três dias atrás, que o servidor provavelmente já contou.
  private let tetoDaFila = 500

  init(baseUrl: String?, armazenamento: Armazenamento, sessao: URLSession = .shared) {
    self.baseUrl = (baseUrl ?? baseUrlPadrao).replacingOccurrences(
      of: "/+$", with: "", options: .regularExpression)
    self.armazenamento = armazenamento
    self.sessao = sessao
  }

  struct Resposta {
    let status: Int
    let corpo: [String: Any]?
    var ok: Bool { (200..<300).contains(status) }
  }

  /** Envia agora. Não guarda nada — quem decide guardar é `enviarOuGuardar`. */
  func enviar(_ metodo: String, _ caminho: String, _ corpo: [String: Any]) async -> Resposta? {
    guard let url = URL(string: baseUrl + caminho) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = metodo
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.timeoutInterval = 15
    req.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
    do {
      let (dados, resposta) = try await sessao.data(for: req)
      let status = (resposta as? HTTPURLResponse)?.statusCode ?? 0
      let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
      return Resposta(status: status, corpo: json ?? nil)
    } catch {
      return nil // rede fora — o chamador guarda
    }
  }

  /**
   Envia e, se não der, guarda para o próximo boot/foreground.
   Devolve `true` quando o fato foi aceito (entregue OU guardado): o dedup do
   recibo só marca depois disso, senão um 5xx apagaria o recibo para sempre.
   */
  @discardableResult
  func enviarOuGuardar(_ metodo: String, _ caminho: String, _ corpo: [String: Any]) async -> Bool {
    if let r = await enviar(metodo, caminho, corpo) {
      if r.ok { return true }
      if r.status >= 400 && r.status < 500 { return false } // não adianta repetir
    }
    guardar(metodo, caminho, corpo)
    return true
  }

  // MARK: - Fila

  func guardar(_ metodo: String, _ caminho: String, _ corpo: [String: Any]) {
    fila.sync {
      var itens = lerFila()
      itens.append(PedidoGuardado(metodo: metodo, caminho: caminho, corpo: emCodavel(corpo), tentativas: 0))
      while itens.count > tetoDaFila { itens.removeFirst() }
      gravarFila(itens)
    }
  }

  /** Reenvia tudo que está guardado. Um item que falha de novo volta para a fila. */
  func esvaziar(resolvendoPlayerId playerId: String?) async {
    let itens = fila.sync { lerFila() }
    guard !itens.isEmpty else { return }
    fila.sync { gravarFila([]) }
    var sobraram: [PedidoGuardado] = []
    for var item in itens {
      var corpo = emDicionario(item.corpo)
      // O recibo pode ter sido guardado ANTES de o registro responder: o
      // player_id nulo é resolvido agora, na hora do envio.
      if corpo["player_id"] is NSNull || corpo["player_id"] == nil, let playerId {
        corpo["player_id"] = playerId
      }
      let r = await enviar(item.metodo, item.caminho, corpo)
      let aceito = r?.ok ?? false
      let descartar = (r?.status ?? 0) >= 400 && (r?.status ?? 0) < 500
      if !aceito && !descartar {
        item.tentativas += 1
        if item.tentativas < 10 { sobraram.append(item) }
      }
    }
    if !sobraram.isEmpty {
      fila.sync {
        var atual = lerFila()
        atual.append(contentsOf: sobraram)
        while atual.count > tetoDaFila { atual.removeFirst() }
        gravarFila(atual)
      }
    }
  }

  var pendentes: Int { fila.sync { lerFila().count } }

  private func lerFila() -> [PedidoGuardado] {
    guard let texto = armazenamento.texto(.fila), let dados = texto.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([PedidoGuardado].self, from: dados)) ?? []
  }
  private func gravarFila(_ itens: [PedidoGuardado]) {
    guard let dados = try? JSONEncoder().encode(itens) else { return }
    armazenamento.guardar(String(data: dados, encoding: .utf8), em: .fila)
  }

  private func emCodavel(_ d: [String: Any]) -> [String: CodavelQualquer] {
    var saida: [String: CodavelQualquer] = [:]
    for (k, v) in d {
      switch v {
      case let s as String: saida[k] = .texto(s)
      case let b as Bool: saida[k] = .logico(b)
      case let n as Int: saida[k] = .numero(Double(n))
      case let n as Double: saida[k] = .numero(n)
      default: saida[k] = .nulo
      }
    }
    return saida
  }
  private func emDicionario(_ d: [String: CodavelQualquer]) -> [String: Any] {
    var saida: [String: Any] = [:]
    for (k, v) in d { saida[k] = v.valor ?? NSNull() }
    return saida
  }
}
