import Foundation
import os

/** Endereço oficial. Igual ao do SDK de JS — errar isto foi o defeito da 0.7.2. */
let baseUrlPadrao = "https://api.pushmesh.io"

/** Um pedido guardado para reenvio. */
struct PedidoGuardado: Codable {
  let metodo: String
  let caminho: String
  let corpo: [String: CodavelQualquer]
  var tentativas: Int
  /// Epoch em segundos a partir de quando pode retentar. `0` = já pode.
  var naoAntesDe: TimeInterval
  /// Nascimento MONÔTONO (epoch s, nunca repetido no processo): é ele que
  /// decide qual escrita de estado é a MAIS NOVA no coalescing.
  var nascidoEm: TimeInterval

  init(metodo: String, caminho: String, corpo: [String: CodavelQualquer],
       tentativas: Int = 0, naoAntesDe: TimeInterval = 0, nascidoEm: TimeInterval = 0) {
    self.metodo = metodo
    self.caminho = caminho
    self.corpo = corpo
    self.tentativas = tentativas
    self.naoAntesDe = naoAntesDe
    self.nascidoEm = nascidoEm
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    metodo = try c.decode(String.self, forKey: .metodo)
    caminho = try c.decode(String.self, forKey: .caminho)
    corpo = try c.decode([String: CodavelQualquer].self, forKey: .corpo)
    tentativas = try c.decode(Int.self, forKey: .tentativas)
    // Fila gravada antes destes campos existirem continua legível: item antigo
    // já pode retentar e é o mais novo que se conhece.
    naoAntesDe = try c.decodeIfPresent(TimeInterval.self, forKey: .naoAntesDe) ?? 0
    nascidoEm = try c.decodeIfPresent(TimeInterval.self, forKey: .nascidoEm) ?? 0
  }
}

/**
 Caixa para JSON heterogêneo — `Codable` não engole `[String: Any]`, e o corpo do
 registro tem string, número, booleano e nulo misturado.
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
 separa do concorrente.

 Orçamento de retry — o MESMO do SDK de JS (`sdk/src/queue.ts`), porque cada
 número dele é cicatriz de defeito já vivido lá. Portar a forma da fila sem
 portar estes números é reescrever o bug com sintaxe nova:

 - backoff exponencial 1s, 2s, 4s… teto 5 min, com JITTER de até 1s. O jitter
   não é enfeite: sem ele, milhares de aparelhos voltando online juntos (fim de
   uma queda de rede) martelam o servidor no mesmo segundo — um SDK sem jitter
   vira ataque ao próprio servidor;
 - `Retry-After` do servidor (429/503) é honrado ACIMA do backoff local, com
   teto de 30 min — honrar o servidor não pode virar item zumbi que nunca
   retenta e ainda ocupa vaga na fila;
 - o esvaziar mantém no máximo 5 pedidos em voo — nunca uma rajada;
 - até 10 tentativas; depois o item é descartado COM aviso (é telemetria, não
   pagamento — melhor perder um recibo que travar a fila para sempre);
 - 4xx — EXCETO 429 — descarta na hora: retry cego não corrige payload errado;
 - ESPERAR REGISTRO NÃO É TENTATIVA FALHA: recibo guardado antes de existir
   `player_id` é adiado sem ida à rede e sem gastar o orçamento de tentativas.
   Contar a espera queimava a cota sem nenhum contato com o servidor, e o recibo
   do onboarding — o mais valioso, o do primeiro push — morria em silêncio só
   porque o registro tinha atrasado.
 */
final class Rede {
  private let baseUrl: String
  private let armazenamento: Armazenamento
  private let sessao: URLSession
  private let fila = DispatchQueue(label: "io.pushmesh.rede")
  private let registro = Logger(subsystem: "io.pushmesh.sdk", category: "Rede")
  /// Relógio e jitter injetáveis — a suíte de testes é determinística com isso.
  private let agora: () -> Date
  private let jitter: () -> Double
  /// Último nascimento emitido (protegido pela queue `fila`) — monotônico.
  private var ultimoNascimento: TimeInterval = 0
  /// Escritas de estado JÁ entregues, por chave × nascimento que superou
  /// (protegido pela queue `fila`): um retry de escrita mais VELHA que já foi
  /// superada por entrega nunca volta para o servidor.
  private var superadas: [String: TimeInterval] = [:]

  /// Teto da fila. Acima disso descarta o MAIS ANTIGO — o recibo de agora vale
  /// mais que o de três dias atrás, que o servidor provavelmente já contou.
  private let tetoDaFila = 500
  private let tetoDeTentativas = 10
  private let atrasoBase: TimeInterval = 1
  private let atrasoTeto: TimeInterval = 5 * 60
  private let jitterTeto: TimeInterval = 1
  /// `Retry-After` acima de 30 min vira 30 min (ver `analisarRetryAfter`).
  private static let tetoRetryAfter: TimeInterval = 30 * 60
  /// Máximo de pedidos em voo num esvaziar — nunca uma rajada por aparelho.
  private let concorrenciaNoEsvaziar = 5

  init(baseUrl: String?, armazenamento: Armazenamento, sessao: URLSession = .shared,
       agora: @escaping () -> Date = { Date() },
       jitter: @escaping () -> Double = { Double.random(in: 0...1) }) {
    self.baseUrl = (baseUrl ?? baseUrlPadrao).replacingOccurrences(
      of: "/+$", with: "", options: .regularExpression)
    self.armazenamento = armazenamento
    self.sessao = sessao
    self.agora = agora
    self.jitter = jitter
  }

  struct Resposta {
    let status: Int
    let corpo: [String: Any]?
    /// Segundos de `Retry-After` (429/503), já capado — a fila honra acima do backoff.
    let retryAfter: TimeInterval?
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
      let http = resposta as? HTTPURLResponse
      let status = http?.statusCode ?? 0
      let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
      let retryAfter = Rede.analisarRetryAfter(http?.value(forHTTPHeaderField: "Retry-After"),
                                               agora: agora())
      return Resposta(status: status, corpo: json ?? nil, retryAfter: retryAfter)
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
      if r.ok {
        // Escrita de estado entregue: supersede qualquer retry mais velho
        // que ainda esteja na fila (o login velho não volta a colar o CPF).
        fila.sync {
          marcarEntrega(PedidoGuardado(
            metodo: metodo, caminho: caminho, corpo: emCodavel(corpo),
            nascidoEm: nascerAgora()))
        }
        return true
      }
      if Rede.descartavel(r.status) {
        registro.warning("[PushMesh] \(metodo, privacy: .public) \(caminho, privacy: .public) recusado (\(r.status)) — retry não corrige payload inválido, descartado")
        return false
      }
      // 429/5xx: honra o Retry-After quando o servidor mandou; nunca martelar
      // quem acabou de pedir pausa.
      guardar(metodo, caminho, corpo, atraso: r.retryAfter ?? atrasoDeTentativa(1))
      return true
    }
    guardar(metodo, caminho, corpo) // rede fora — o próximo esvaziar tenta
    return true
  }

  // MARK: - Atrasos

  /// 4xx descarta — MENOS o 429, que é "volta mais tarde", não "payload errado".
  static func descartavel(_ status: Int) -> Bool {
    (400..<500).contains(status) && status != 429
  }

  /**
   `Retry-After` em segundos (número) ou data HTTP, devolvido em segundos já
   capado. Teto de 30 min: um proxy/CDN mal configurado devolvendo data
   distante (ou segundos absurdos) agendaria o item para semanas à frente —
   ele nunca mais retentava e ainda ocupava vaga na fila, expulsando recibos
   legítimos. Lixo nas duas formas ⇒ `nil` (o header é ignorado).
   */
  static func analisarRetryAfter(_ bruto: String?, agora: Date) -> TimeInterval? {
    guard let bruto = bruto?.trimmingCharacters(in: .whitespaces), !bruto.isEmpty else { return nil }
    if let segundos = Double(bruto) { return min(max(segundos, 0), tetoRetryAfter) }
    let formato = DateFormatter()
    formato.locale = Locale(identifier: "en_US_POSIX")
    formato.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let data = formato.date(from: bruto) else { return nil }
    return min(max(data.timeIntervalSince(agora), 0), tetoRetryAfter)
  }

  /**
   Backoff exponencial (1s, 2s, 4s…, teto 5 min) + jitter de até 1s.
   `n` é a tentativa que VAI acontecer (`1` = primeira retentativa).
   */
  func atrasoDeTentativa(_ n: Int) -> TimeInterval {
    min(atrasoBase * pow(2, Double(n)), atrasoTeto) + jitter() * jitterTeto
  }

  // MARK: - Fila

  /**
   Chave de ESTADO de um item (Lei 3 do `queue.ts` do JS): mesmo recurso +
   mesmos campos. PUT é escrita de estado — o servidor aplica o corpo POR CIMA
   do que existe, e reenviar um PUT VELHO depois de um novo já entregue
   re-cola dados velhos (o login voltando a colar o CPF num aparelho
   deslogado). POST é fato imutável (recibo, evento) e nunca coalesce:
   `nil`.
   */
  private static func chaveDeEstado(_ metodo: String, _ caminho: String, _ corpo: [String: Any]) -> String? {
    guard metodo == "PUT" else { return nil }
    let campos = corpo.keys.filter { $0 != "app_id" }.sorted().joined(separator: ",")
    return "\(caminho)#\(campos)"
  }

  /** Nascimento monotônico: nunca repetido, nunca para trás (Lei 3). */
  private func nascerAgora() -> TimeInterval {
    let t = agora().timeIntervalSince1970
    ultimoNascimento = max(t, ultimoNascimento + 0.001)
    return ultimoNascimento
  }

  /**
   Guarda para reenvio. `atraso` é quanto esperar antes da primeira tentativa.
   PUT de estado COALESCE: a escrita mais nova de cada chave substitui a antiga
   que ainda está na fila (a velha virou lixo — nunca foi entregue e já não
   vale nada).
   */
  func guardar(_ metodo: String, _ caminho: String, _ corpo: [String: Any], atraso: TimeInterval = 0) {
    fila.sync {
      var itens = lerFila()
      if let chave = Rede.chaveDeEstado(metodo, caminho, corpo) {
        itens.removeAll { Rede.chaveDeEstado($0.metodo, $0.caminho, emDicionario($0.corpo)) == chave }
      }
      itens.append(PedidoGuardado(
        metodo: metodo, caminho: caminho, corpo: emCodavel(corpo),
        naoAntesDe: agora().timeIntervalSince1970 + atraso,
        nascidoEm: nascerAgora()))
      while itens.count > tetoDaFila { itens.removeFirst() }
      gravarFila(itens)
    }
  }

  /** Marca a entrega de uma escrita de estado: supera retries mais velhos. */
  private func marcarEntrega(_ item: PedidoGuardado) {
    guard item.metodo == "PUT",
          let chave = Rede.chaveDeEstado(item.metodo, item.caminho, emDicionario(item.corpo)) else { return }
    if superadas[chave, default: 0] < item.nascidoEm { superadas[chave] = item.nascidoEm }
  }

  /// Escrita superada por uma entrega mais nova: é lixo, não volta ao servidor.
  private func estaSuperado(_ item: PedidoGuardado) -> Bool {
    guard let chave = Rede.chaveDeEstado(item.metodo, item.caminho, emDicionario(item.corpo)) else { return false }
    return item.nascidoEm < (superadas[chave] ?? 0)
  }

  /**
   Reenvia o que está guardado E já pode — item esperando o atraso do retry
   fica na fila, intocado. Quem chega à fila DURANTE o esvaziar não é
   sobrescrito no regravar final.

   O lote due sai da fila e vai para `pm:fila_em_voo` ANTES da rede (Lei 1):
   o esvaziar dispara no arranque — exatamente quando a pessoa fecha o app —
   e morrer no meio da rede não pode perder o lote. O lote órfão de um flush
   morto volta para cá na próxima rodada; a duplicata eventual é absorvida
   pelo servidor (recibo: `pm:rcpt NX`; PUT: idempotente).
   */
  func esvaziar(resolvendoPlayerId playerId: String?) async {
    let instante = agora().timeIntervalSince1970
    let itens = fila.sync { () -> [PedidoGuardado] in
      let orfaos = lerEmVoo()
      if !orfaos.isEmpty { gravarEmVoo([]) }
      return lerFila() + orfaos
    }
    let vivos = itens.filter { !estaSuperado($0) }
    let devidos = vivos.filter { $0.naoAntesDe <= instante }
    let adiados = vivos.filter { $0.naoAntesDe > instante }
    guard !devidos.isEmpty else {
      // Sem nada due ainda sai daqui — mas superado é LIXO: sair da fila não
      // pode depender de chegar a hora dele (ficaria contando para sempre).
      if vivos.count != itens.count { fila.sync { gravarFila(adiados) } }
      return
    }
    fila.sync {
      gravarFila(adiados)
      gravarEmVoo(devidos)
    }

    var sobraram: [PedidoGuardado] = []
    for pedaco in devidos.emPedacos(de: concorrenciaNoEsvaziar) {
      await withTaskGroup(of: PedidoGuardado?.self) { grupo in
        for item in pedaco {
          grupo.addTask { await self.processar(item, playerId: playerId, instante: instante) }
        }
        for await sobrevivente in grupo {
          if let sobrevivente { sobraram.append(sobrevivente) }
        }
      }
    }
    fila.sync {
      gravarEmVoo([]) // lote resolvido — a Lei 1 cumpriu seu papel
      var atual = lerFila().filter { !estaSuperado($0) }
      atual.append(contentsOf: sobraram)
      while atual.count > tetoDaFila { atual.removeFirst() }
      gravarFila(atual)
    }
  }

  /**
   Processa um item due. Devolve o item para continuar na fila, ou `nil` quando
   ele está resolvido (entregue ou descartado).
   */
  private func processar(_ item: PedidoGuardado, playerId: String?,
                         instante: TimeInterval) async -> PedidoGuardado? {
    var item = item
    var corpo = emDicionario(item.corpo)
    // O recibo pode ter sido guardado ANTES de o registro responder: o
    // player_id nulo é resolvido agora, na hora do envio. Só o campo
    // EXPLICITAMENTE nulo espera — PUT de permissão não carrega player_id no
    // corpo (o id mora no caminho) e não pode ficar preso esperando registro.
    if corpo["player_id"] is NSNull {
      guard let playerId else {
        // ESPERAR REGISTRO NÃO É TENTATIVA FALHA: adia sem gastar o orçamento.
        item.naoAntesDe = instante + atrasoDeTentativa(item.tentativas + 1)
        return item
      }
      corpo["player_id"] = playerId
    }

    let r = await enviar(item.metodo, item.caminho, corpo)
    if r?.ok == true {
      marcarEntrega(item) // escrita de estado entregue supersede as velhas
      return nil
    }
    let status = r?.status ?? 0
    if Rede.descartavel(status) {
      registro.warning("[PushMesh] item da fila descartado (\(status)) em \(item.caminho, privacy: .public) — retry não corrige payload inválido")
      return nil
    }
    item.tentativas += 1
    guard item.tentativas < tetoDeTentativas else {
      registro.warning("[PushMesh] item da fila descartado após \(self.tetoDeTentativas) tentativas em \(item.caminho, privacy: .public) — telemetria não vale fila travada")
      return nil
    }
    item.naoAntesDe = instante + (r?.retryAfter ?? atrasoDeTentativa(item.tentativas))
    return item
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
  /// Lote em voo de um esvaziar (Lei 1) — morrer no meio da rede não perde.
  private func lerEmVoo() -> [PedidoGuardado] {
    guard let texto = armazenamento.texto(.filaEmVoo), let dados = texto.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([PedidoGuardado].self, from: dados)) ?? []
  }
  private func gravarEmVoo(_ itens: [PedidoGuardado]) {
    guard let dados = try? JSONEncoder().encode(itens) else { return }
    armazenamento.guardar(String(data: dados, encoding: .utf8), em: .filaEmVoo)
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

private extension Array {
  func emPedacos(de tamanho: Int) -> [[Element]] {
    stride(from: 0, to: count, by: tamanho).map {
      Array(self[$0..<Swift.min($0 + tamanho, count)])
    }
  }
}
