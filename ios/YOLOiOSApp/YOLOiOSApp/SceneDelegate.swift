// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import UIKit
import UltralyticsYOLO

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = (scene as? UIWindowScene) else { return }

    window = UIWindow(windowScene: windowScene)
    window?.rootViewController = RecordViewController()
    window?.makeKeyAndVisible()
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    ExternalDisplayManager.refreshModeIfNeeded()
  }
}

/// Camera preview with one button: Record runs the bundled `best` model with live boxes, Stop pauses it.
private final class RecordViewController: UIViewController {
  private lazy var yoloView = YOLOView(frame: view.bounds)
  private let button = UIButton(configuration: .filled())
  private var isRunning = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    yoloView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Alpha rather than isHidden: YOLOView re-shows some of its controls during layout.
    yoloView.subviews.forEach { $0.alpha = 0 }
    [yoloView.sliderConf, yoloView.labelSliderConf].forEach { $0.alpha = 1 }
    yoloView.excludedClasses = ["longitudinal_crack", "transverse_crack"]
    view.addSubview(yoloView)

    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration?.cornerStyle = .capsule
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(
      top: 16, leading: 40, bottom: 16, trailing: 40)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setRunning(!self.isRunning)
      }, for: .touchUpInside)
    view.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    setRunning(false)
    button.isEnabled = false
    button.configuration?.title = "Loading"
    yoloView.setModel(
      modelPathOrName: Bundle.main.path(forResource: "Models/Detect/best", ofType: "mlpackage")
        ?? "",
      task: .detect
    ) { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          self?.button.isEnabled = true
          self?.setRunning(false)
        case .failure(let error):
          print(error)
          self?.button.configuration?.title = "Model failed to load"
        }
      }
    }
  }

  private func setRunning(_ running: Bool) {
    isRunning = running
    yoloView.setInferenceFlag(ok: running)
    yoloView.showOverlays = running  // Turning this off also clears the boxes left on screen.
    button.configuration?.title = running ? "Stop" : "Record"
    button.configuration?.baseBackgroundColor = running ? .darkGray : .systemRed
  }
}
