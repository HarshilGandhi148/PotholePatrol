// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import CoreMotion
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
  private let sizeEstimator = ObjectSizeEstimator()
  private let motion = CMMotionManager()
  private let heightStepper = UIStepper()
  private let heightLabel = UILabel()
  private let debugLabel = UILabel()
  private var isRunning = false

  private static let heightKey = "cameraHeightMeters"
  /// The phone's height above the road, in meters. Size scales directly with this, so measure it with a tape.
  private var cameraHeight: Double {
    get { UserDefaults.standard.object(forKey: Self.heightKey) as? Double ?? 1.2 }
    set { UserDefaults.standard.set(newValue, forKey: Self.heightKey) }
  }

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

    heightStepper.minimumValue = 0.5
    heightStepper.maximumValue = 3
    heightStepper.stepValue = 0.05
    heightStepper.value = cameraHeight
    heightStepper.overrideUserInterfaceStyle = .dark
    heightStepper.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.cameraHeight = self.heightStepper.value
        self.showCameraHeight()
        self.sizeEstimator.reset()  // Earlier measurements used the old height.
      }, for: .valueChanged)
    heightLabel.textColor = .white
    heightLabel.font = .preferredFont(forTextStyle: .caption1)
    heightLabel.textAlignment = .right
    showCameraHeight()
    let heightControl = UIStackView(arrangedSubviews: [heightLabel, heightStepper])
    heightControl.axis = .vertical
    heightControl.alignment = .trailing
    heightControl.spacing = 4
    heightControl.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(heightControl)

    debugLabel.translatesAutoresizingMaskIntoConstraints = false
    debugLabel.textColor = .yellow
    debugLabel.backgroundColor = .black.withAlphaComponent(0.5)
    debugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    debugLabel.numberOfLines = 0
    debugLabel.textAlignment = .center
    #if DEBUG
      view.addSubview(debugLabel)
      NSLayoutConstraint.activate([
        debugLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        debugLabel.topAnchor.constraint(equalTo: modelPicker.bottomAnchor, constant: 44),
      ])
    #endif

    NSLayoutConstraint.activate([
      modelPicker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      modelPicker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      heightControl.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      heightControl.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    loadModel(at: modelPicker.selectedSegmentIndex)
  }

  private func showCameraHeight() {
    heightLabel.text = String(format: "Phone height %.2f m", cameraHeight)
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

  /// The camera's position over the road for this frame, or `nil` if its sensors aren't ready.
  private func groundCamera(for result: YOLOResult) -> GroundPlaneCamera? {
    guard let matrix = result.cameraIntrinsics, let gravity = motion.deviceMotion?.gravity,
      let orientation = bufferOrientation
    else { return nil }
    return GroundPlaneCamera(
      intrinsics: CameraIntrinsics(matrix: matrix).matched(to: result.orig_shape),
      down: orientation.cameraDown(
        fromDeviceGravity: SIMD3(gravity.x, gravity.y, gravity.z)),
      height: cameraHeight)
  }

  /// `YOLOView` keeps the video buffers rotated to match the interface.
  private var bufferOrientation: BufferOrientation? {
    switch view.window?.windowScene?.interfaceOrientation {
    case .portrait: return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    default: return nil
    }
  }

  /// Adds this frame's measurements, then returns each tracked pothole's label text, such as "≈24×18 in · 3.2 m".
  private func sizeLabels(for tracks: [TrackedDetection], in result: YOLOResult) -> [Int: String] {
    sizeEstimator.retain(ids: Set(tracks.map(\.id)))
    if let camera = groundCamera(for: result), let rotation = motion.deviceMotion?.rotationRate {
      let rotationRate = sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z)
      for track in tracks {
        guard let rect = track.measuredRect else { continue }
        sizeEstimator.add(
          id: track.id, rect: rect, imageSize: result.orig_shape, camera: camera,
          rotationRate: rotationRate)
      }
    }

    let inchesPerMeter = 39.3701
    var labels = [Int: String]()
    for track in tracks {
      guard let size = sizeEstimator.size(id: track.id) else { continue }
      let width = Int((size.width * inchesPerMeter).rounded())
      let dimensions =
        size.length.map { "≈\(width)×\(Int(($0 * inchesPerMeter).rounded())) in" }
        ?? "≈\(width) in wide"
      labels[track.id] = dimensions + String(format: " · %.1f m", size.distance)
    }
    return labels
  }

  /// Shows the raw sensor values, so they can be checked on a real phone.
  private func updateDebugReadout(for result: YOLOResult) {
    #if DEBUG
      guard let matrix = result.cameraIntrinsics, let camera = groundCamera(for: result) else {
        debugLabel.text = "waiting for camera and motion data"
        return
      }
      let raw = CameraIntrinsics(matrix: matrix)
      let degreesPerRadian = 180 / Double.pi
      debugLabel.text = String(
        format: "raw fx %.0f fy %.0f cx %.0f cy %.0f\nimage %.0f×%.0f fx %.0f fy %.0f\ntilt down %.1f° roll %.1f°",
        raw.fx, raw.fy, raw.cx, raw.cy, result.orig_shape.width, result.orig_shape.height,
        camera.intrinsics.fx, camera.intrinsics.fy,
        asin(camera.down.z) * degreesPerRadian,
        atan2(camera.down.x, camera.down.y) * degreesPerRadian)
    #endif
  }

  /// Replaces one frame's raw boxes with the tracker's steady ones, labeled with their size once it's known.
  private func steadied(_ result: YOLOResult) -> YOLOResult {
    let detections = result.boxes.map {
      TrackerDetection(
        rect: $0.xywhn, confidence: $0.conf, classIndex: $0.index, className: $0.cls)
    }
    let tracks = tracker.update(
      detections, at: CACurrentMediaTime(),
      appearThreshold: Float(yoloView.getConfidenceThreshold()))
    updateDebugReadout(for: result)
    let labels = sizeLabels(for: tracks, in: result)
    let size = result.orig_shape
    return result.replacingBoxes(
      tracks.map { track in
        Box(
          index: track.classIndex, cls: track.className, conf: track.confidence,
          xywh: CGRect(
            x: track.rect.minX * size.width, y: track.rect.minY * size.height,
            width: track.rect.width * size.width, height: track.rect.height * size.height),
          xywhn: track.rect, detail: labels[track.id])
      })
  }

  private func setRunning(_ running: Bool) {
    isRunning = running
    tracker.reset()
    sizeEstimator.reset()
    if running {
      motion.deviceMotionUpdateInterval = 1.0 / 30
      motion.startDeviceMotionUpdates()
    } else {
      motion.stopDeviceMotionUpdates()
    }
    yoloView.setInferenceFlag(ok: running)
    yoloView.showOverlays = running  // Turning this off also clears the boxes left on screen.
    button.configuration?.title = running ? "Stop" : "Record"
    button.configuration?.baseBackgroundColor = running ? .darkGray : .systemRed
  }
}
