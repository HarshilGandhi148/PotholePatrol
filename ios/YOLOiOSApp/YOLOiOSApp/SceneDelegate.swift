// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import UIKit
import SwiftUI
import UltralyticsYOLO

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: windowScene)
    window?.rootViewController = UIHostingController(rootView: PotholePatrolRootView())
    window?.makeKeyAndVisible()
  }
}

/// Retains the existing YOLOView/setModel camera path; SwiftUI owns the scan controls.
@MainActor
final class RecordViewController: UIViewController {
  private let model: ScannerViewModel
  private var yoloView: YOLOView?
  init(model: ScannerViewModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("Use init(model:)") }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .black
    let camera = YOLOView(frame: view.bounds)
    camera.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    camera.subviews.forEach { $0.alpha = 0 }
    camera.excludedClasses = ["longitudinal_crack", "transverse_crack"]
    camera.setInferenceFlag(ok: false); camera.showOverlays = false
    camera.onDetection = { [weak self] result in self?.model.received(result) }
    view.addSubview(camera); yoloView = camera
    model.captureAction = { [weak self] in self?.capturePothole() }
    // Keep the selected production-intended YOLO11n package and the SDK's existing loader.
    guard let path = Bundle.main.path(forResource: "Models/Detect/pothole-yolo11n", ofType: "mlpackage") else {
      model.error = "Bundled pothole-yolo11n.mlpackage is missing. Check the Models resource in Xcode."; model.stop(); return
    }
    camera.setModel(modelPathOrName: path, task: .detect) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.model.running else { return }
        switch result {
        case .success:
          self.model.ready = true; self.model.modelStatus = "YOLO11n · ready"
          self.yoloView?.showOverlays = true; self.yoloView?.setInferenceFlag(ok: true)
        case .failure(let error):
          self.model.modelStatus = "Model load failed"; self.model.error = error.localizedDescription; self.model.stop()
        }
      }
    }
  }
  private func capturePothole() {
    guard let yoloView, model.ready, !model.capturing else { return }
    model.capturing = true
    let captureTime = Date(); let position = model.location.freshLocation(at: captureTime)
    // The SDK takes a still, runs its predictor on that image, then renders the share image with overlays.
    // Disable streaming inference while doing so; the user reviews the resulting photo before upload.
    yoloView.setInferenceFlag(ok: false)
    yoloView.capturePhoto { [model] image in
      model.captured(image: image, at: captureTime, location: position)
    }
  }
  func stopCamera() { yoloView?.setInferenceFlag(ok: false); yoloView?.stop(); model.captureAction = nil }
  override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stopCamera() }
}
