import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/**
 Captura do token do APNs e das notificações que chegam.

 Duas portas, de propósito:

 1. **Automática** — instalamos um delegado-proxy no `UNUserNotificationCenter` e
    trocamos (swizzle) os dois métodos de token no delegado do app. É o "uma
    linha e funciona".
 2. **Manual** — `PushMesh.registrarToken(_:)` e `PushMesh.processarPush(_:)`.
    Existe porque swizzle é hostil a quem já tem outro SDK de push no app, e
    porque um SDK que só funciona por mágica é um SDK que ninguém consegue
    depurar às três da manhã.
 */
final class Apns: NSObject {
  static let compartilhado = Apns()

  /// Delegado que já existia — todo evento é repassado para ele. Não sequestramos
  /// o app do cliente: se ele já mostrava notificação de outro jeito, continua.
  private weak var delegadoAnterior: UNUserNotificationCenterDelegate?
  private var aoReceberToken: ((Data) -> Void)?
  private var aoFalharToken: ((Error) -> Void)?
  private var aoReceberPush: (([AnyHashable: Any], Recibos.Evento) -> Void)?

  func instalar(
    aoReceberToken: @escaping (Data) -> Void,
    aoFalharToken: @escaping (Error) -> Void,
    aoReceberPush: @escaping ([AnyHashable: Any], Recibos.Evento) -> Void
  ) {
    self.aoReceberToken = aoReceberToken
    self.aoFalharToken = aoFalharToken
    self.aoReceberPush = aoReceberPush

    let centro = UNUserNotificationCenter.current()
    if centro.delegate !== self {
      delegadoAnterior = centro.delegate
      centro.delegate = self
    }
    trocarMetodosDoDelegadoDoApp()
  }

  /** Pede o token ao sistema. Idempotente — o iOS responde rápido se já houver registro. */
  func registrarNoApns() {
    #if canImport(UIKit)
    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
    #endif
  }

  func tokenEmHex(_ dados: Data) -> String { dados.map { String(format: "%02x", $0) }.joined() }

  // MARK: - Swizzle dos callbacks de token

  private func trocarMetodosDoDelegadoDoApp() {
    #if canImport(UIKit)
    guard let delegado = UIApplication.shared.delegate else { return }
    let classe: AnyClass = type(of: delegado)

    trocar(
      classe: classe,
      original: #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)),
      substituto: #selector(Apns.pm_application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
    )
    trocar(
      classe: classe,
      original: #selector(UIApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)),
      substituto: #selector(Apns.pm_application(_:didFailToRegisterForRemoteNotificationsWithError:))
    )
    #endif
  }

  /**
   Troca um método do delegado do app pelo nosso.

   Quando o app NÃO implementa o método, apenas adicionamos o nosso — é o caso
   comum e o mais seguro. Quando implementa, trocamos as implementações e o
   nosso chama o original: o app continua recebendo o callback dele.
   */
  private func trocar(classe: AnyClass, original: Selector, substituto: Selector) {
    guard let nosso = class_getInstanceMethod(Apns.self, substituto) else { return }
    let impNossa = method_getImplementation(nosso)
    let tipos = method_getTypeEncoding(nosso)

    if let existente = class_getInstanceMethod(classe, original) {
      // Guarda a original sob um nome nosso e troca.
      let guardado = Selector("pm_original_\(NSStringFromSelector(original))")
      if class_addMethod(classe, guardado, method_getImplementation(existente), method_getTypeEncoding(existente)) {
        method_setImplementation(existente, impNossa)
      }
    } else {
      class_addMethod(classe, original, impNossa, tipos)
    }
  }

  #if canImport(UIKit)
  @objc func pm_application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken dados: Data) {
    Apns.compartilhado.aoReceberToken?(dados)
    let guardado = Selector("pm_original_application:didRegisterForRemoteNotificationsWithDeviceToken:")
    if (self as AnyObject).responds(to: guardado) {
      _ = (self as AnyObject).perform(guardado, with: app, with: dados)
    }
  }

  @objc func pm_application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError erro: Error) {
    Apns.compartilhado.aoFalharToken?(erro)
    let guardado = Selector("pm_original_application:didFailToRegisterForRemoteNotificationsWithError:")
    if (self as AnyObject).responds(to: guardado) {
      _ = (self as AnyObject).perform(guardado, with: app, with: erro)
    }
  }
  #endif
}

// MARK: - Notificações que chegam

extension Apns: UNUserNotificationCenterDelegate {
  /// App ABERTO. É aqui que nasce a maior parte dos recibos de iOS.
  func userNotificationCenter(
    _ centro: UNUserNotificationCenter,
    willPresent notificacao: UNNotification,
    withCompletionHandler completar: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    aoReceberPush?(notificacao.request.content.userInfo, .recebido)
    if let anterior = delegadoAnterior,
       anterior.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
      anterior.userNotificationCenter?(centro, willPresent: notificacao, withCompletionHandler: completar)
      return
    }
    // Sem delegado anterior, mostramos a notificação: o app que não decidiu nada
    // espera VER o push que pediu.
    completar([.banner, .sound, .badge, .list])
  }

  /// A pessoa TOCOU na notificação.
  func userNotificationCenter(
    _ centro: UNUserNotificationCenter,
    didReceive resposta: UNNotificationResponse,
    withCompletionHandler completar: @escaping () -> Void
  ) {
    aoReceberPush?(resposta.notification.request.content.userInfo, .clique)
    if let anterior = delegadoAnterior,
       anterior.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
      anterior.userNotificationCenter?(centro, didReceive: resposta, withCompletionHandler: completar)
      return
    }
    completar()
  }
}
