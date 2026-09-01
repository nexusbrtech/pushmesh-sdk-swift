# PushMesh SDK — native Swift

> **Português:** [README.pt-BR.md](README.pt-BR.md)

Push for **Swift/UIKit/SwiftUI** apps, without React Native. It speaks the same
contract as the JavaScript SDK and uses the **same storage keys** (`pm:*`): an
app migrating from React Native to native keeps the same `player_id` and does
not become a duplicate device in the panel.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/nexusbrtech/pushmesh-sdk-swift", from: "0.1.1")
```

CocoaPods, if SPM is not your thing:

```ruby
pod 'PushMeshSDK', '~> 0.1.1'
```

## Use — one call

```swift
import PushMeshSDK

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ app: UIApplication,
                   didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Task { await PushMesh.iniciar(appId: "YOUR_APP_ID", pedirPermissao: true) }
    return true
  }
}
```

Nothing else is needed. The APNs token is captured on its own, the device
registers itself, and the delivery receipt comes back when the push arrives.

> The public API is in Portuguese by design — it is the convention of the whole
> product, applied consistently. `iniciar` = init · `entrar`/`sair` =
> login/logout · `pedirPermissao` = request permission.

### `pedirPermissao` is opt-in on purpose

The default is `false`. On iOS a person is asked **once in the app's lifetime**
— burning that chance in the first second, before they understand what they
get, is the most expensive way to lose a subscriber. Call
`PushMesh.pedirPermissao()` at the moment that makes sense in your product.

## In Xcode, the two steps Apple requires

1. **Signing & Capabilities → + Capability → Push Notifications**
2. **Background Modes → Remote notifications**

Without the first one the system **never** hands out a token — and the SDK says
exactly that in `PushMesh.ultimoAviso`.

## API

| | |
|---|---|
| `iniciar(appId:appVersion:baseUrl:pedirPermissao:)` | turns the SDK on and registers the device |
| `entrar(_:)` / `sair()` | binds/unbinds your app's user |
| `pedirPermissao()` | requests permission and reports it to the server |
| `playerId`, `token` | registration state |
| `diagnostico()` | a snapshot of the state, for debugging |
| `ultimoAviso` | the SDK's last warning, readable by the app |

### Without swizzling

The SDK captures the system callbacks via swizzling. If your app already has
another push SDK and you prefer control, call it by hand:

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

## `ultimoAviso` — why it exists

On Android, `adb logcat` shows the SDK's diagnostics. On iOS there is no
equivalent: the warning dies in a console that only exists with the debugger
attached. We measured this in the field — the cause of a failure stayed
invisible for hours. An SDK that promises to shout must shout where it can be
heard, so the last warning is available as API.

## Known limit — background receipts

Today the iOS delivery receipt counts **what the app sees**: app open, or a tap
on the notification. With the app in background or killed, the push arrives and
shows, but no receipt goes out. On Android the receipt is real in all three
states. The service extension (`NotificationService`) is where the fix belongs,
and it is the next front.

## Tests

```sh
swift test
```

The suite covers what can be proven **without a device**: the offline queue
(cap of 500 with FIFO discard, the 10-attempt budget, backoff with jitter,
`Retry-After` honored, at most 5 requests in flight, the in-flight batch that
survives the app dying mid-flush, PUT coalescing that keeps an old write from
landing on top of a new one), the receipt's LRU-64 dedup (marked only after
acceptance) and the registration payload assembly (the contract's exact key
set). Concurrency is proven against a real TCP server on loopback —
`URLProtocol` serializes requests and would always measure a peak of 1.

**What this suite does NOT prove:** registration against real APNs,
entitlements, swizzling, a notification showing on screen. Those boundaries
only fall on a simulator/device — that is the project's boundary ritual, and a
green suite does not replace it.
