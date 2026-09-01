import Foundation

/**
 Recibo de entrega — a única promessa que nos separa do concorrente.

 O disparo embute no payload do push:
   `pm_msg_id` — id da notificação
   `pm_rcpt`   — a prova HMAC calculada NO SERVIDOR (a chave nunca sai de lá)

 O SDK só devolve a prova. Quem confere é o servidor.
 */
public final class Recibos {
  private let rede: Rede
  private let armazenamento: Armazenamento
  private let tetoLru = 64

  init(rede: Rede, armazenamento: Armazenamento) {
    self.rede = rede
    self.armazenamento = armazenamento
  }

  /// Público porque aparece na assinatura de `PushMesh.processarPush`.
  public enum Evento: String { case recebido, clique }

  /**
   Ponto de entrada: passe o `userInfo` do push. Silencioso para pushes que não
   são nossos (sem `pm_msg_id`) — o app host pode receber push de outra origem.
   */
  @discardableResult
  func processar(_ userInfo: [AnyHashable: Any], evento: Evento = .recebido,
                 appId: String, playerId: String?) async -> Bool {
    guard let msgId = userInfo["pm_msg_id"] as? String,
          let prova = userInfo["pm_rcpt"] as? String else { return false }
    return await enviar(notificacao: msgId, prova: prova, evento: evento,
                        appId: appId, playerId: playerId)
  }

  /**
   ORDEM É LEI: o "já visto" só é marcado DEPOIS de o envio ser aceito.
   Marcar antes matava o recibo para sempre — um 5xx no primeiro envio e a
   reentrega do APNs batia no dedup e ia embora calada.
   */
  @discardableResult
  func enviar(notificacao: String, prova: String, evento: Evento,
              appId: String, playerId: String?) async -> Bool {
    // Entrega e clique são fatos DISTINTOS da mesma notificação: se a chave do
    // dedup fosse só o id, o clique bateria no "já visto" (a entrega sempre
    // passa antes) e o painel mostraria zero clique para sempre.
    let chave = evento == .recebido ? notificacao : "\(notificacao)#\(evento.rawValue)"
    if jaVisto(chave) { return false }

    var corpo: [String: Any] = [
      "app_id": appId,
      "notification_id": notificacao,
      "rcpt": prova,
      "evento": evento.rawValue,
    ]
    // Sem registro ainda (1º push chegando antes de o POST /players responder):
    // NÃO vai para a rede — o backend exige player_id (responde 400) e 4xx
    // descarta na origem. Vai para a fila; o esvaziar resolve o id na hora do
    // envio e, enquanto ele não existe, ADIA sem gastar tentativa.
    let aceito: Bool
    if let playerId {
      corpo["player_id"] = playerId
      aceito = await rede.enviarOuGuardar("POST", "/api/v1/receipts", corpo)
    } else {
      corpo["player_id"] = NSNull()
      rede.guardar("POST", "/api/v1/receipts", corpo)
      aceito = true // guardado = aceito; o dedup marca e a reentrega não duplica
    }
    if aceito { marcarVisto(chave) }
    return aceito
  }

  private func jaVisto(_ chave: String) -> Bool { armazenamento.lista(.lruRecibos).contains(chave) }

  private func marcarVisto(_ chave: String) {
    var lista = armazenamento.lista(.lruRecibos)
    lista.removeAll { $0 == chave }
    lista.append(chave)
    while lista.count > tetoLru { lista.removeFirst() }
    armazenamento.guardar(lista, em: .lruRecibos)
  }
}
