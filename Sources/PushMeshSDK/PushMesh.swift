import Foundation
import UserNotifications
import os

/**
 PushMesh — SDK nativo para iOS, sem React Native.

 Uso mínimo, num app Swift qualquer:

 ```swift
 // AppDelegate.application(_:didFinishLaunchingWithOptions:)
 Task { await PushMesh.iniciar(appId: "seu-app-id", pedirPermissao: true) }
 ```

 Não precisa de mais nada: o token do APNs é capturado sozinho, o aparelho se
 registra e o recibo de entrega volta quando o push chega.
 */
public enum PushMesh {

  // MARK: - Estado interno

  private final class Estado {
    var appId: String?
    var appVersion: String?
    var token: String?
    var playerId: String?
    var usuarioExterno: String?
    var saidaPendente = false
    var rede: Rede?
    var recibos: Recibos?
    var armazenamento = Armazenamento()
    var ultimoAviso: String?
    var esperandoToken: [CheckedContinuation<String?, Never>] = []
  }
  private static let estado = Estado()
  private static let registro = Logger(subsystem: "io.pushmesh.sdk", category: "PushMesh")

  /// Último aviso do SDK, legível pelo app.
  ///
  /// Existe por um defeito de produto que medimos em campo: no iOS não há
  /// `adb logcat`. O aviso mais importante — "o aparelho está mudo", "faltou a
  /// capability de push" — morria num console que só aparece com o depurador
  /// aberto. Um SDK que se propõe a gritar precisa gritar onde dá para escutar.
  public static var ultimoAviso: String? { estado.ultimoAviso }

  /// Identificador do aparelho no PushMesh. `nil` até o registro terminar.
  public static var playerId: String? { estado.playerId ?? estado.armazenamento.texto(.playerId) }

  /// Token do APNs em hexadecimal, quando já veio.
  public static var token: String? { estado.token ?? estado.armazenamento.texto(.token) }

  // MARK: - Ciclo de vida

  /**
   Liga o SDK: captura o token do APNs, registra o aparelho e esvazia a fila
   offline. Chame no arranque do app.

   - Parameter pedirPermissao: quando `true`, pede a permissão de notificação
     na hora. O padrão é `false` DE PROPÓSITO: no iOS a pessoa é perguntada uma
     única vez na vida do app, e queimar essa chance no primeiro segundo — antes
     de ela entender o que ganha — é a forma mais cara de perder um assinante.
   */
  @discardableResult
  public static func iniciar(
    appId: String,
    appVersion: String? = nil,
    baseUrl: String? = nil,
    pedirPermissao: Bool = false
  ) async -> String? {
    estado.appId = appId
    estado.appVersion = appVersion
    estado.rede = Rede(baseUrl: baseUrl, armazenamento: estado.armazenamento)
    estado.recibos = Recibos(rede: estado.rede!, armazenamento: estado.armazenamento)
    estado.playerId = estado.armazenamento.texto(.playerId)
    estado.usuarioExterno = estado.armazenamento.texto(.usuarioExterno)
    estado.armazenamento.guardar((estado.armazenamento.inteiro(.sessoes) ?? 0) + 1, em: .sessoes)

    Apns.compartilhado.instalar(
      aoReceberToken: { dados in
        let hex = Apns.compartilhado.tokenEmHex(dados)
        estado.token = hex
        estado.armazenamento.guardar(hex, em: .token)
        let esperando = estado.esperandoToken
        estado.esperandoToken = []
        esperando.forEach { $0.resume(returning: hex) }
      },
      aoFalharToken: { erro in
        avisar(
          "falha ao obter o token APNs: \(erro.localizedDescription). Como corrigir: "
            + "habilite a capability 'Push Notifications' no alvo do app (e Background "
            + "Modes → Remote notifications). Sem o entitlement aps-environment o "
            + "sistema nunca entrega um token — nem no simulador."
        )
        let esperando = estado.esperandoToken
        estado.esperandoToken = []
        esperando.forEach { $0.resume(returning: nil) }
      },
      aoReceberPush: { userInfo, evento in
        Task { await processarPush(userInfo, evento: evento) }
      }
    )

    if pedirPermissao { _ = await self.pedirPermissao() }

    Apns.compartilhado.registrarNoApns()
    let token = await esperarToken(segundos: 10)
    guard token != nil else {
      // Sem token não há registro. A fila ainda é esvaziada: recibos represados
      // de uma sessão anterior não têm culpa do token de agora.
      await estado.rede?.esvaziar(resolvendoPlayerId: playerId)
      return nil
    }
    let id = await registrar()
    await estado.rede?.esvaziar(resolvendoPlayerId: id)
    await reportarPermissao()
    return id
  }

  /** Amarra um usuário do app ao aparelho (ex.: id interno, CPF). */
  public static func entrar(_ usuarioExterno: String) async {
    estado.usuarioExterno = usuarioExterno
    estado.saidaPendente = false
    estado.armazenamento.guardar(usuarioExterno, em: .usuarioExterno)
    guard let appId = estado.appId else { return }
    if let id = playerId {
      await estado.rede?.enviarOuGuardar("PUT", "/api/v1/players/\(id)", [
        "app_id": appId, "external_user_id": usuarioExterno,
      ])
    } else {
      _ = await registrar()
    }
  }

  /**
   Desamarra o usuário.

   Manda `null` EXPLÍCITO: o servidor distingue "campo ausente" (não mexe) de
   "null" (limpa). Omitir deixaria o id do usuário colado no aparelho para
   sempre — e um aparelho emprestado receberia push de quem já saiu.
   */
  public static func sair() async {
    estado.usuarioExterno = nil
    estado.saidaPendente = true
    estado.armazenamento.apagar(.usuarioExterno)
    guard let appId = estado.appId, let id = playerId else { return }
    let ok = await estado.rede?.enviarOuGuardar("PUT", "/api/v1/players/\(id)", [
      "app_id": appId, "external_user_id": NSNull(),
    ])
    if ok == true { estado.saidaPendente = false }
  }

  // MARK: - Permissão

  /** Pede a permissão de notificação e reporta o resultado ao servidor. */
  @discardableResult
  public static func pedirPermissao() async -> Bool {
    let centro = UNUserNotificationCenter.current()
    let concedida = (try? await centro.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    if !concedida {
      avisar(
        "o aparelho está MUDO: a permissão de notificação não foi concedida. "
          + "Todo push será aceito pelo APNs e NÃO vai aparecer na tela — e o recibo "
          + "de entrega nunca vai contar. Reative em Ajustes → o app → Notificações."
      )
    }
    await reportarPermissao()
    return concedida
  }

  /** Reporta ao servidor se o aparelho pode ou não exibir notificação. */
  public static func reportarPermissao() async {
    let ajustes = await UNUserNotificationCenter.current().notificationSettings()
    let tipos = ajustes.authorizationStatus == .authorized || ajustes.authorizationStatus == .provisional ? 1 : 0
    estado.armazenamento.guardar(tipos, em: .tiposNotificacao)
    guard let appId = estado.appId, let id = playerId else { return }
    await estado.rede?.enviarOuGuardar("PUT", "/api/v1/players/\(id)", [
      "app_id": appId, "notification_types": tipos,
    ])
  }

  // MARK: - Portas manuais (para quem não quer swizzle)

  /// Chame de `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  public static func registrarToken(_ dados: Data) {
    let hex = Apns.compartilhado.tokenEmHex(dados)
    estado.token = hex
    estado.armazenamento.guardar(hex, em: .token)
    Task { _ = await registrar() }
  }

  /// Chame com o `userInfo` de qualquer push recebido.
  public static func processarPush(_ userInfo: [AnyHashable: Any], evento: Recibos.Evento = .recebido) async {
    guard let appId = estado.appId else { return }
    await estado.recibos?.processar(userInfo, evento: evento, appId: appId, playerId: playerId)
  }

  // MARK: - Diagnóstico

  /**
   Retrato do estado, para o integrador ver o que está acontecendo.
   É a resposta ao defeito de produto que motivou `ultimoAviso`.
   */
  public static func diagnostico() -> [String: Any] {
    [
      "sdk": versaoDoSDK,
      "app_id": estado.appId ?? "(sem init)",
      "player_id": playerId ?? "(não registrado)",
      "token": token.map { String($0.prefix(16)) + "…" } ?? "(sem token APNs)",
      "transporte": "apns",
      "tipos_notificacao": estado.armazenamento.inteiro(.tiposNotificacao) ?? -1,
      "usuario_externo": estado.usuarioExterno ?? "(nenhum)",
      "fila_pendente": estado.rede?.pendentes ?? 0,
      "ultimo_aviso": ultimoAviso ?? "(nenhum)",
      "modelo": Perfil.modelo,
    ]
  }

  // MARK: - Interno

  private static func avisar(_ texto: String) {
    estado.ultimoAviso = texto
    registro.warning("[PushMesh] \(texto, privacy: .public)")
  }

  private static func esperarToken(segundos: Int) async -> String? {
    if let t = estado.token { return t }
    return await withTaskGroup(of: String?.self) { grupo in
      grupo.addTask {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
          estado.esperandoToken.append(c)
        }
      }
      grupo.addTask {
        try? await Task.sleep(nanoseconds: UInt64(segundos) * 1_000_000_000)
        return nil
      }
      let primeiro = await grupo.next() ?? nil
      grupo.cancelAll()
      return primeiro
    }
  }

  /**
   POST /api/v1/players — idempotente pelo hash do payload.

   O hash evita um POST por abertura de app quando nada mudou. Guardar o
   `player_id` e o hash JUNTOS importa: gravá-los separados já deixou o id de um
   registro com o hash de outro, e o recibo (HMAC amarrado ao player_id) passou a
   voltar 403 — entrega perdida sem ninguém ver.
   */
  @discardableResult
  private static func registrar() async -> String? {
    guard let appId = estado.appId, let rede = estado.rede else { return nil }
    guard let token = estado.token ?? estado.armazenamento.texto(.token) else {
      avisar("sem token do APNs — o aparelho não pode ser registrado ainda.")
      return nil
    }

    var payload: [String: Any] = [
      "app_id": appId,
      "identifier": token,
      "device_type": 0,      // 0 = iOS
      "transporte": "apns",  // APNs direto, sem Firebase
    ]
    if let usuario = estado.usuarioExterno {
      payload["external_user_id"] = usuario
    } else if estado.saidaPendente {
      payload["external_user_id"] = NSNull()
    }
    payload.merge(Perfil.campos(appVersion: estado.appVersion)) { atual, _ in atual }

    let hash = hashDoPayload(payload)
    if estado.armazenamento.texto(.regHash) == hash, let id = estado.armazenamento.texto(.playerId) {
      estado.playerId = id
      return id // nada mudou — nem chama o servidor
    }

    guard let resposta = await rede.enviar("POST", "/api/v1/players", payload) else {
      avisar("POST /players não completou (rede). O SDK tenta de novo no próximo arranque.")
      return nil
    }
    guard resposta.ok, let id = resposta.corpo?["id"] as? String else {
      avisar("POST /players respondeu \(resposta.status).")
      return nil
    }
    estado.playerId = id
    estado.armazenamento.guardar(id, em: .playerId)
    estado.armazenamento.guardar(hash, em: .regHash)
    estado.armazenamento.guardar("apns", em: .transporte)
    if estado.saidaPendente { estado.saidaPendente = false }
    return id
  }

  private static func hashDoPayload(_ payload: [String: Any]) -> String {
    let chaves = payload.keys.sorted()
    let texto = chaves.map { "\($0)=\(payload[$0].map { "\($0)" } ?? "nil")" }.joined(separator: "&")
    var h: UInt64 = 5381
    for b in texto.utf8 { h = (h &* 33) &+ UInt64(b) }
    return String(h, radix: 16)
  }
}
