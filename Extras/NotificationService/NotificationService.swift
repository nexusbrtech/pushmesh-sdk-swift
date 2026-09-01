import Foundation
import UserNotifications

/**
 * Notification Service Extension do PUSHMESH — a peça que faz a IMAGEM
 * aparecer no push do iOS.
 *
 * POR QUE ESTE ARQUIVO EXISTE (e por que ele não pode morar dentro do app):
 * o servidor já manda tudo que é preciso — `mutable-content: 1` no `aps` e a
 * URL da imagem no payload. Só que no iOS QUEM baixa a imagem é o aparelho,
 * num processo SEPARADO do app, e esse processo só existe se o projeto tiver
 * um alvo (target) do tipo Notification Service Extension. Sem esse alvo o
 * iOS ignora o `mutable-content` em silêncio e a notificação chega sem
 * imagem — exatamente o sintoma "no Android a imagem aparece, no iOS não".
 * É exigência da Apple, não limitação do SDK: nenhum código dentro do app
 * consegue substituir a extensão, porque em background/app morto o app nem
 * roda. Passo a passo de instalação: LEIA-ME.md, nesta mesma pasta.
 *
 * O QUE ESTA EXTENSÃO FAZ (só isto — de propósito):
 *   1. lê a URL da imagem no payload (chaves do servidor, ver `PushMeshAnexo`);
 *   2. baixa com prazo curto e teto de tamanho;
 *   3. grava num arquivo temporário com a extensão CERTA (.jpg/.png/.gif);
 *   4. anexa e entrega.
 *
 * A LEI DESTE ARQUIVO: a notificação NUNCA some. Imagem é enfeite; a mensagem
 * é a promessa. Falha de rede, 404, formato que a Apple não aceita, arquivo
 * gigante, tempo esgotado — todo caminho de erro entrega o conteúdo ORIGINAL.
 * O `contentHandler` é chamado EXATAMENTE UMA VEZ, sempre (chamar duas vezes
 * é comportamento indefinido; não chamar faz o iOS entregar uma notificação
 * degradada depois de ~30s).
 *
 * O QUE ESTA EXTENSÃO **NÃO** FAZ (não é esquecimento, é escopo):
 * recibo de entrega em background/app morto. Isso é outra frente — exigiria
 * a extensão conhecer appId/baseUrl e falar com o servidor. Enquanto não
 * chega, o recibo do iOS segue contando o que o app vê (foreground/toque),
 * como está documentado no README do SDK.
 *
 * DEPENDÊNCIAS: nenhuma. Só Foundation + UserNotifications, ambos do SDK do
 * sistema. Sem CocoaPods, sem App Group, sem Keychain compartilhado — por
 * isso a instalação é "criar o alvo e apontar este arquivo", e nada mais.
 */

// MARK: - Partes puras (é o que o cenário executável dos testes exercita)

/// Leitura do payload e decisão do formato — SEM rede e SEM UNNotification*,
/// para poder ser exercitado por um binário de teste de verdade
/// (`__tests__/ios/cenario_nse.swift`).
enum PushMeshAnexo {

  // As chaves são as do servidor (src/domain/payload.rs). Mudou lá, muda aqui
  // — e o teste `ios-nse.test.ts` lê o Rust e falha se os nomes divergirem.

  /// `ios_attachments` da API: objeto `{nome: url}`. Vai no payload APNs nos
  /// DOIS caminhos de envio (APNs direto e via FCM).
  static let CHAVE_ANEXOS = "pm_attachments"

  /// `big_picture` da API — a imagem única, a que o painel de fato manda.
  /// No APNs direto ela chega na RAIZ do payload; no caminho FCM ela sai em
  /// `message.data` e o FCM copia os dados para as chaves custom do APNs.
  static let CHAVE_IMAGEM = "pm_big_picture"

  /// Espelho da mesma URL no bloco de exibição do Android (`pmx_image`).
  /// Só é usado se as duas de cima faltarem: custa uma linha e salva o caso
  /// de um payload antigo/parcial chegar sem `pm_big_picture`.
  static let CHAVE_IMAGEM_ESPELHO = "pmx_image"

  /// Teto do arquivo baixado. A Apple recusa anexo de imagem acima de 10 MB —
  /// baixar mais que isso é gastar a janela para levar erro na cara.
  static let TETO_BYTES = 10 * 1024 * 1024

  /// Prazo de UMA tentativa de download. A Apple dá ~30s para a extensão
  /// inteira; 10s deixa folga para uma segunda URL e para gravar o anexo.
  static let TIMEOUT_SEGUNDOS: TimeInterval = 10

  /// Prazo de TODAS as tentativas somadas. Passou disto, entrega sem imagem —
  /// esperar o tapa do sistema entregaria uma notificação pior.
  static let JANELA_TOTAL_SEGUNDOS: TimeInterval = 20

  /// URLs candidatas, na ordem de preferência e sem repetição.
  ///
  /// A ordem dos anexos é por NOME ORDENADO, não a ordem do JSON: o payload
  /// vira dicionário (NSDictionary), que não tem ordem — sem ordenar, duas
  /// entregas do mesmo push podiam escolher imagens diferentes.
  static func urlsCandidatas(_ userInfo: [AnyHashable: Any]) -> [String] {
    var achadas: [String] = []

    func juntar(_ valor: Any?) {
      guard let texto = normalizar(valor) else { return }
      if !achadas.contains(texto) { achadas.append(texto) }
    }

    if let anexos = userInfo[CHAVE_ANEXOS] as? [String: Any] {
      for nome in anexos.keys.sorted() { juntar(anexos[nome]) }
    }
    juntar(userInfo[CHAVE_IMAGEM])
    juntar(userInfo[CHAVE_IMAGEM_ESPELHO])
    return achadas
  }

  /// String não vazia e absoluta http(s) — o resto não é URL de mídia.
  static func normalizar(_ valor: Any?) -> String? {
    guard let texto = (valor as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !texto.isEmpty else { return nil }
    let minuscula = texto.lowercased()
    guard minuscula.hasPrefix("https://") || minuscula.hasPrefix("http://") else { return nil }
    return texto
  }

  /// Extensão de arquivo + UTI do anexo, ou `nil` se o formato não serve.
  ///
  /// POR QUE A EXTENSÃO IMPORTA: o `UNNotificationAttachment` decide o tipo
  /// pelo NOME do arquivo. Arquivo sem extensão (ou com extensão errada) é
  /// recusado e a imagem some — e o download da CDN vem, quase sempre, com
  /// nome/URL sem extensão nenhuma.
  ///
  /// A ordem da decisão é do mais confiável para o menos:
  ///   1. os bytes do arquivo (verdade absoluta, não mente);
  ///   2. o `Content-Type` da resposta (CDN mal configurada manda
  ///      `application/octet-stream`);
  ///   3. a extensão na URL (some em URL assinada/`?token=`).
  ///
  /// Só jpg/png/gif: são os formatos de imagem que a Apple aceita em anexo.
  /// WEBP/HEIC/AVIF são recusados — por isso a mídia do painel deve ser
  /// jpg/png/gif.
  static func formatoSuportado(
    bytes: [UInt8],
    contentType: String?,
    url: String?
  ) -> (extensao: String, uti: String)? {
    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
      return ("jpg", "public.jpeg")
    }
    if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
      return ("png", "public.png")
    }
    if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
      return ("gif", "com.compuserve.gif")
    }

    if let tipo = contentType?
      .split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces)
      .lowercased() {
      switch tipo {
      case "image/jpeg", "image/jpg": return ("jpg", "public.jpeg")
      case "image/png": return ("png", "public.png")
      case "image/gif": return ("gif", "com.compuserve.gif")
      default: break
      }
    }

    if let sufixo = extensaoDaUrl(url) {
      switch sufixo {
      case "jpg", "jpeg": return ("jpg", "public.jpeg")
      case "png": return ("png", "public.png")
      case "gif": return ("gif", "com.compuserve.gif")
      default: break
      }
    }
    return nil
  }

  /// Extensão no caminho da URL, já sem `?query` e sem `#fragmento`.
  static func extensaoDaUrl(_ url: String?) -> String? {
    guard let url else { return nil }
    let caminho = url.split(separator: "?").first.map(String.init) ?? url
    let semAncora = caminho.split(separator: "#").first.map(String.init) ?? caminho
    guard let ultimo = semAncora.split(separator: "/").last else { return nil }
    let partes = ultimo.split(separator: ".")
    guard partes.count >= 2, let sufixo = partes.last else { return nil }
    return sufixo.lowercased()
  }
}

// MARK: - A extensão

/// Classe principal do alvo. O nome é o mesmo que o Xcode dá ao criar o alvo
/// (`NotificationService`), então o `NSExtensionPrincipalClass` do Info.plist
/// gerado — `$(PRODUCT_MODULE_NAME).NotificationService` — já aponta para cá
/// e NÃO precisa ser editado. Trocar o nome desta classe sem trocar o
/// Info.plist faz a extensão não rodar EM SILÊNCIO (a imagem simplesmente
/// não aparece, sem erro nenhum): não troque.
final class NotificationService: UNNotificationServiceExtension {

  private var entregar: ((UNNotificationContent) -> Void)?
  private var conteudo: UNMutableNotificationContent?
  private var original: UNNotificationContent?
  private var tarefa: URLSessionDownloadTask?
  private var candidatas: [String] = []
  private var limite = Date.distantPast

  /// Guarda da entrega única. O `serviceExtensionTimeWillExpire` chega numa
  /// thread DIFERENTE da resposta do download: sem trava, os dois podiam
  /// chamar o `contentHandler` no mesmo instante.
  private let trava = NSLock()
  private var jaEntregue = false

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    entregar = contentHandler
    original = request.content
    conteudo = request.content.mutableCopy() as? UNMutableNotificationContent
    limite = Date().addingTimeInterval(PushMeshAnexo.JANELA_TOTAL_SEGUNDOS)
    candidatas = PushMeshAnexo.urlsCandidatas(request.content.userInfo)

    // Sem imagem no payload (a maioria dos pushes): entrega JÁ. A extensão
    // roda em todo push com mutable-content — segurar aqui atrasaria tudo.
    if candidatas.isEmpty { entregarUmaVezSo(); return }

    guard conteudo != nil else {
      // Nunca visto em campo; se acontecer, a mensagem vai intacta.
      NSLog("[PushMesh NSE] conteúdo não é mutável — entregando sem imagem")
      entregarUmaVezSo()
      return
    }
    tentarProxima()
  }

  /// Fim da janela da Apple (~30s). Entregar aqui é OBRIGATÓRIO: sem isto o
  /// sistema mostra a notificação sem passar pelo nosso conteúdo.
  override func serviceExtensionTimeWillExpire() {
    NSLog(
      "[PushMesh NSE] a janela da extensão expirou antes de a imagem baixar — "
        + "entregando a notificação SEM imagem (a mensagem nunca é sacrificada). "
        + "Como corrigir: imagem menor (< 1 MB) ou CDN mais rápida.")
    tarefa?.cancel()
    entregarUmaVezSo()
  }

  // MARK: - Passos

  private func tentarProxima() {
    guard !candidatas.isEmpty else { entregarUmaVezSo(); return }
    guard Date() < limite else {
      NSLog("[PushMesh NSE] tempo de download esgotado — entregando sem imagem")
      entregarUmaVezSo()
      return
    }
    let texto = candidatas.removeFirst()
    guard let url = URL(string: texto) else {
      NSLog(
        "[PushMesh NSE] URL de imagem inválida: %@. "
          + "Como corrigir: mande a mídia como URL absoluta https:// e sem espaços.",
        texto)
      tentarProxima()
      return
    }
    baixar(url) { [weak self] deuCerto in
      guard let self else { return }
      if deuCerto { self.entregarUmaVezSo() } else { self.tentarProxima() }
    }
  }

  private func baixar(_ url: URL, _ pronto: @escaping (Bool) -> Void) {
    // Sessão efêmera: a extensão vive segundos, não faz sentido deixar cache
    // e cookies no contêiner dela.
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = PushMeshAnexo.TIMEOUT_SEGUNDOS
    config.timeoutIntervalForResource = PushMeshAnexo.TIMEOUT_SEGUNDOS
    config.waitsForConnectivity = false
    let sessao = URLSession(configuration: config)

    // downloadTask (e não dataTask): o corpo vai direto para disco — imagem
    // grande não passa pela memória de um processo que o iOS mata sem dó.
    let tarefa = sessao.downloadTask(with: url) { [weak self] temporario, resposta, erro in
      defer { sessao.finishTasksAndInvalidate() }
      guard let self else { pronto(false); return }
      pronto(self.anexar(temporario: temporario, resposta: resposta, erro: erro, url: url))
    }
    self.tarefa = tarefa
    tarefa.resume()
  }

  /// Valida o que veio e anexa. Devolve `false` para qualquer motivo de
  /// desistência — e todo `false` é logado com causa + como corrigir, porque
  /// o sintoma no aparelho é sempre o mesmo (imagem some) e sem log o
  /// operador não tem como saber se a culpa é da URL, do formato ou do peso.
  private func anexar(
    temporario: URL?,
    resposta: URLResponse?,
    erro: Error?,
    url: URL
  ) -> Bool {
    if let erro {
      let dica =
        url.scheme?.lowercased() == "http"
        ? " A URL é http:// — o iOS bloqueia por App Transport Security. "
          + "Como corrigir: publique a mídia em https://."
        : " Como corrigir: confira se a URL abre no navegador e se a CDN responde rápido."
      NSLog("[PushMesh NSE] download da imagem falhou: %@.%@", erro.localizedDescription, dica)
      return false
    }
    guard let temporario else { return false }

    if let http = resposta as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      NSLog(
        "[PushMesh NSE] a CDN respondeu %ld para a imagem. "
          + "Como corrigir: verifique se a URL é pública (sem login/token expirado).",
        http.statusCode)
      return false
    }

    let atributos = try? FileManager.default.attributesOfItem(atPath: temporario.path)
    let bytes = (atributos?[.size] as? NSNumber)?.intValue ?? 0
    guard bytes > 0 else {
      NSLog("[PushMesh NSE] a imagem baixada veio vazia — entregando sem imagem")
      return false
    }
    guard bytes <= PushMeshAnexo.TETO_BYTES else {
      NSLog(
        "[PushMesh NSE] imagem de %ld bytes acima do teto de %ld. "
          + "Como corrigir: a Apple recusa anexo de imagem acima de 10 MB — "
          + "publique uma versão comprimida.",
        bytes, PushMeshAnexo.TETO_BYTES)
      return false
    }

    let contentType = (resposta as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
    guard
      let formato = PushMeshAnexo.formatoSuportado(
        bytes: primeirosBytes(temporario, 12),
        contentType: contentType,
        url: url.absoluteString)
    else {
      NSLog(
        "[PushMesh NSE] formato de imagem não reconhecido (Content-Type: %@). "
          + "Como corrigir: o iOS só aceita jpg, png e gif em anexo de notificação — "
          + "webp/heic/avif não entram.",
        contentType ?? "ausente")
      return false
    }

    // O arquivo do downloadTask é apagado quando este bloco retorna: mover
    // para uma pasta nossa (com a extensão certa no nome) é obrigatório.
    let pasta = FileManager.default.temporaryDirectory
      .appendingPathComponent("pushmesh-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
      let destino = pasta.appendingPathComponent("imagem.\(formato.extensao)")
      try FileManager.default.moveItem(at: temporario, to: destino)
      // identifier vazio = o sistema gera um; o typeHint evita que o iOS
      // tenha de adivinhar o tipo de novo.
      let anexo = try UNNotificationAttachment(
        identifier: "",
        url: destino,
        options: [UNNotificationAttachmentOptionsTypeHintKey: formato.uti])
      conteudo?.attachments = [anexo]
      return true
    } catch {
      // O anexo consome o arquivo quando dá certo; quando dá errado, a
      // sujeira é nossa para limpar.
      try? FileManager.default.removeItem(at: pasta)
      NSLog("[PushMesh NSE] não deu para anexar a imagem: %@", error.localizedDescription)
      return false
    }
  }

  /// Cabeça do arquivo para farejar o formato — lê só alguns bytes, nunca a
  /// imagem inteira.
  private func primeirosBytes(_ arquivo: URL, _ quantos: Int) -> [UInt8] {
    guard let fh = try? FileHandle(forReadingFrom: arquivo) else { return [] }
    defer { try? fh.close() }
    let dados = (try? fh.read(upToCount: quantos)) ?? Data()
    return [UInt8](dados)
  }

  /// Entrega o melhor conteúdo que existir — uma vez só, venha de onde vier.
  private func entregarUmaVezSo() {
    trava.lock()
    if jaEntregue {
      trava.unlock()
      return
    }
    jaEntregue = true
    let mao = entregar
    let carga = conteudo ?? original
    entregar = nil
    trava.unlock()

    if let mao, let carga { mao(carga) }
  }
}
