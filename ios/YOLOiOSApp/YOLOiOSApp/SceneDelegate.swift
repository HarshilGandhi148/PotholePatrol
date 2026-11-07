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

/// Camera preview with a model picker and one button: Record runs the selected bundled model with live boxes, Stop
/// pauses it.
private final class RecordViewController: UIViewController {
  /// Every model we compared on real potholes. YOLO11n won, so it is the only one offered in the picker.
  /// YOLOv8s is not bundled because its author states no license (see README).
  private let models = [
    (title: "RDD v8m", resource: "best", inPicker: false),
    (title: "YOLO11n", resource: "pothole-yolo11n", inPicker: true),
    (title: "YOLOv8s", resource: "pothole-yolov8s", inPicker: false),
  ]
  private lazy var pickerModels = models.filter(\.inPicker)
  private lazy var yoloView = YOLOView(frame: view.bounds)
  private lazy var modelPicker = UISegmentedControl(items: pickerModels.map(\.title))
  private let button = UIButton(configuration: .filled())
  private let tracker = DetectionTracker()
  private var isRunning = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    yoloView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Alpha rather than isHidden: YOLOView re-shows some of its controls during layout.
    yoloView.subviews.forEach { $0.alpha = 0 }
    [yoloView.sliderConf, yoloView.labelSliderConf, yoloView.labelFPS].forEach { $0.alpha = 1 }
    yoloView.excludedClasses = ["longitudinal_crack", "transverse_crack"]
    // The tracker applies the slider's threshold, and needs weaker detections to keep known potholes alive.
    yoloView.fixedInferenceConfidence = 0.10
    yoloView.resultTransform = { [weak self] result in
      self?.steadied(result) ?? result
    }
    view.addSubview(yoloView)

    modelPicker.translatesAutoresizingMaskIntoConstraints = false
    modelPicker.overrideUserInterfaceStyle = .dark
    modelPicker.backgroundColor = .black.withAlphaComponent(0.5)
    modelPicker.selectedSegmentIndex = 0
    modelPicker.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.loadModel(at: self.modelPicker.selectedSegmentIndex)
      }, for: .valueChanged)
    view.addSubview(modelPicker)

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
      modelPicker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      modelPicker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    loadModel(at: modelPicker.selectedSegmentIndex)
  }

  /// Swaps in a bundled model, keeping detection running across the switch if it was already on.
  private func loadModel(at index: Int) {
    let wasRunning = isRunning
    setRunning(false)
    modelPicker.isEnabled = false
    button.isEnabled = false
    button.configuration?.title = "Loading"
    yoloView.setModel(
      modelPathOrName: Bundle.main.path(
        forResource: "Models/Detect/\(pickerModels[index].resource)", ofType: "mlpackage")
        ?? "",
      task: .detect
    ) { [weak self] result in
      DispatchQueue.main.async {
        self?.modelPicker.isEnabled = true
        switch result {
        case .success:
          self?.button.isEnabled = true
          self?.setRunning(wasRunning)
        case .failure(let error):
          print(error)
          self?.button.configuration?.title = "Model failed to load"
        }
      }
    }
  }

  /// Replaces one frame's raw boxes with the tracker's steady ones.
  private func steadied(_ result: YOLOResult) -> YOLOResult {
    let detections = result.boxes.map {
      TrackerDetection(
        rect: $0.xywhn, confidence: $0.conf, classIndex: $0.index, className: $0.cls)
    }
    let tracks = tracker.update(
      detections, at: CACurrentMediaTime(),
      appearThreshold: Float(yoloView.getConfidenceThreshold()))
    let size = result.orig_shape
    return result.replacingBoxes(
      tracks.map { track in
        Box(
          index: track.classIndex, cls: track.className, conf: track.confidence,
          xywh: CGRect(
            x: track.rect.minX * size.width, y: track.rect.minY * size.height,
            width: track.rect.width * size.width, height: track.rect.height * size.height),
          xywhn: track.rect)
      })
  }

  private func setRunning(_ running: Bool) {
    isRunning = running
    tracker.reset()
    yoloView.setInferenceFlag(ok: running)
    yoloView.showOverlays = running  // Turning this off also clears the boxes left on screen.
    button.configuration?.title = running ? "Stop" : "Record"
    button.configuration?.baseBackgroundColor = running ? .darkGray : .systemRed
  }
}
