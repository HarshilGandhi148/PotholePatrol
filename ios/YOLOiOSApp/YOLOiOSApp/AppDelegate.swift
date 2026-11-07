// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    // Use ordinary mirroring for external screens. The legacy dedicated scene creates its own camera.
    if connectingSceneSession.role.isExternalDisplay {
      return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    return UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role
    )
  }
}
