// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import UIKit

/// The app stays in portrait, except that Live Scan can rotate for a phone mounted on a dashboard.
@MainActor
enum OrientationLock {
  fileprivate(set) static var mask = UIInterfaceOrientationMask.portrait

  static func allowLandscape() {
    mask = .allButUpsideDown
    updateWindows()
  }

  static func returnToPortrait() {
    mask = .portrait
    updateWindows()
  }

  private static func updateWindows() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
  }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    OrientationLock.mask
  }

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
