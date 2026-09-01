# PushMesh SDK — Swift nativo

Push para apps **Swift/UIKit/SwiftUI**, sem React Native. Fala o mesmo contrato
do SDK de JavaScript e usa as **mesmas chaves de armazenamento** (`pm:*`): um app
que migra de React Native para nativo mantém o mesmo `player_id` e não vira um
aparelho duplicado no painel.

## Instalar

Swift Package Manager:

```swift
.package(url: "https://github.com/nexusbrtech/pushmesh-sdk-swift", from: "0.1.0")
```

CocoaPods, para quem não usa SPM:

```ruby
pod 'PushMeshSDK', '~> 0.1.0'
```

## Usar — uma chamada

```swift
import PushMeshSDK

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ app: UIApplication,
                   didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Task { await PushMesh.iniciar(appId: "SEU_APP_ID", pedirPermissao: true) }
    return true
  }
}
```

Não precisa de mais nada. O token do APNs é capturado sozinho, o aparelho se
registra e o recibo de entrega volta quando o push chega.

### `pedirPermissao` é opt-in de propósito

O padrão é `false`. No iOS a pessoa é perguntada **uma única vez na vida do app**
— queimar essa chance no primeiro segundo, antes de ela entender o que ganha, é
a forma mais cara de perder um assinante. Chame `PushMesh.pedirPermissao()` no
momento em que fizer sentido no seu produto.

## No Xcode, dois passos que a Apple obriga

1. **Signing & Capabilities → + Capability → Push Notifications**
2. **Background Modes → Remote notifications**

Sem o primeiro, o sistema **nunca** entrega um token e o SDK avisa exatamente
isso em `PushMesh.ultimoAviso`.

## API

| | |
|---|---|
| `iniciar(appId:appVersion:baseUrl:pedirPermissao:)` | liga o SDK e registra o aparelho |
| `entrar(_:)` / `sair()` | amarra/desamarra o usuário do seu app |
| `pedirPermissao()` | pede a permissão e reporta ao servidor |
| `playerId`, `token` | estado do registro |
| `diagnostico()` | retrato do estado, para depurar |
| `ultimoAviso` | o último aviso do SDK, legível pelo app |

### Sem swizzle

O SDK captura os callbacks do sistema por swizzling. Se o seu app já tem outro
SDK de push e você prefere controlar, chame na mão:

```swift
func application(_ a: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken t: Data) {
  PushMesh.registrarToken(t)
}
func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
  Task { await PushMesh.processarPush(n.request.content.userInfo) }
  done([.banner, .sound])
}
```

## `ultimoAviso` — por que existe

No Android o `adb logcat` mostra o diagnóstico do SDK. No iOS não existe
equivalente: o aviso morre num console que só aparece com o depurador aberto.
Medimos isso em campo — a causa de uma falha ficou invisível por horas. Um SDK
que se propõe a gritar precisa gritar onde dá para escutar, então o último aviso
fica disponível por API.

## Limite conhecido — recibo em segundo plano

Hoje o recibo de iOS conta **o que o app vê**: app aberto ou toque na
notificação. Com o app em segundo plano ou morto, o push chega e aparece, mas o
recibo não sai. No Android o recibo é real nos três estados. A extensão de
serviço (`NotificationService`) é o lugar do conserto e é a próxima frente.

## Testes

```sh
cd pushmesh/sdk-swift && swift test
```

A suíte cobre o que dá para provar **sem aparelho**: a fila offline (teto de
500 com descarte FIFO, o orçamento de 10 tentativas, backoff com jitter,
`Retry-After` honrado, o máximo de 5 pedidos em voo, o lote em voo que
sobrevive à morte do app no meio do esvaziar, o coalescing de PUTs que impede
escrita velha de voltar por cima da nova), o dedup LRU-64 do recibo (a
marcação só depois do aceite) e a montagem do payload de registro (o conjunto
exato de chaves do contrato). Concorrência é provada contra um servidor TCP
real em loopback — `URLProtocol` serializa os requests e mediria pico 1
sempre.

**O que esta suíte NÃO prova:** registro com APNs de verdade, entitlement,
swizzle, notificação aparecendo na tela. Essas fronteiras só caem no
simulador/aparelho — é o ritual de fronteira do projeto
(`memoria/postmortem-falha-silenciosa.md`), e suíte verde não o substitui.
