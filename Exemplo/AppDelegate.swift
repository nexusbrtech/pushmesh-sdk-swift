import UIKit

/**
 App de exemplo — Swift puro, UIKit, zero React Native.

 É o laboratório de certificação do SDK nativo: se este app não conseguir, um
 cliente também não consegue. Só API pública do pacote.
 */
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  static var tela: TelaDeLog?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let tela = AppDelegate.tela ?? TelaDeLog()
    AppDelegate.tela = tela

    tela.escrever("app Swift puro — ciclo de vida de CENA (iOS 27)")
    tela.escrever("sdk \(versaoDoSDK)")

    Task {
      let inicio = Date()
      let id = await PushMesh.iniciar(
        appId: "01a0545f-32af-72a1-b8b8-454ac678aa4f",
        appVersion: "1.0.0",
        pedirPermissao: true
      )
      let ms = Int(Date().timeIntervalSince(inicio) * 1000)
      tela.escrever("iniciar resolveu em \(ms) ms")
      tela.escrever(id == nil ? "player_id = NULO — não registrou" : "player_id = \(id!)")
      await PushMesh.entrar("lab-swift-1")
      tela.escrever("entrar(\"lab-swift-1\") ok")
      for (chave, valor) in PushMesh.diagnostico().sorted(by: { $0.key < $1.key }) {
        tela.escrever("  \(chave) = \(valor)")
      }
    }
    return true
  }

  /// Exigido a partir do iOS 27: sem isto o app nem sobe, e aí não existe
  /// token, não existe registro e nenhum push chega. A mudança é do ciclo de
  /// vida do APP — os callbacks de push continuam no UIApplicationDelegate,
  /// que é onde o SDK se pendura.
  func application(_ app: UIApplication,
                   configurationForConnecting sessao: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let cfg = UISceneConfiguration(name: "Padrao", sessionRole: sessao.role)
    cfg.delegateClass = SceneDelegate.self
    return cfg
  }

  /// O app do cliente JÁ implementa o callback de token. O SDK precisa capturar
  /// o token E deixar este método continuar funcionando — é o ramo do swizzle
  /// que mais quebra SDK de push na prática.
  func application(_ app: UIApplication,
                   didRegisterForRemoteNotificationsWithDeviceToken dados: Data) {
    AppDelegate.tela?.escrever("APP: meu proprio callback rodou (\(dados.count) bytes)")
  }
}

/** Log na tela — no iOS não existe `adb logcat`, então o lab mostra o que acontece. */
final class TelaDeLog: UIViewController {
  private let texto = UITextView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1)
    texto.frame = view.bounds.insetBy(dx: 12, dy: 60)
    texto.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    texto.backgroundColor = .clear
    texto.textColor = UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
    texto.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    texto.isEditable = false
    view.addSubview(texto)
  }

  func escrever(_ linha: String) {
    DispatchQueue.main.async {
      let hora = DateFormatter()
      hora.dateFormat = "HH:mm:ss.SSS"
      self.texto.text += "\(hora.string(from: Date())) \(linha)\n"
    }
  }
}


/// Cena — é ela que cria a janela agora, com `UIWindow(windowScene:)`.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ cena: UIScene, willConnectTo sessao: UISceneSession,
             options: UIScene.ConnectionOptions) {
    guard let cenaDeJanela = cena as? UIWindowScene else { return }
    let tela = AppDelegate.tela ?? TelaDeLog()
    AppDelegate.tela = tela
    let janela = UIWindow(windowScene: cenaDeJanela)
    janela.rootViewController = tela
    janela.makeKeyAndVisible()
    window = janela
  }
}
