// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import CoreLocation
import CoreMotion
import SwiftUI
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
    window?.rootViewController = UIHostingController(rootView: PotholePatrolRootView())
    window?.makeKeyAndVisible()
  }
}

/// Live Scan's camera preview with a model picker and one button: Start runs the selected bundled model with live
/// boxes, Stop pauses it.
final class RecordViewController: UIViewController {
  /// A pothole seen during this Live Scan, kept in memory until it can be sent to the backend.
  struct DetectedPothole {
    let width: Double
    let length: Double?
    let area: Double?
    let coordinate: GeoCoordinate?
    let lastSeen: Date
  }

  private let location: LocationService
  private let onClose: () -> Void
  private(set) var detectedPotholes = [Int: DetectedPothole]()
  /// Whether the motion attitude is referenced to north, so it can give the camera's compass direction.
  private var hasCompassAttitude = false

  init(location: LocationService, onClose: @escaping () -> Void) {
    self.location = location
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use init(location:onClose:)") }

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
  private let heightSlider = UISlider()
  private let heightLabel = UILabel()
  private let scanStatus = UILabel()
  private var isRunning = false

  private static let heightKey = "cameraHeightMeters"
  /// The phone's height above the road, in meters. Size scales directly with this, so measure it with a tape.
  private var cameraHeight: Double {
    get { UserDefaults.standard.object(forKey: Self.heightKey) as? Double ?? 1.0 }
    set { UserDefaults.standard.set(newValue, forKey: Self.heightKey) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    yoloView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Alpha rather than isHidden: YOLOView re-shows some of its controls during layout.
    yoloView.subviews.forEach { $0.alpha = 0 }
    [yoloView.sliderConf, yoloView.labelSliderConf].forEach { $0.alpha = 1 }
    yoloView.sliderConf.tintColor = UIColor(PatrolTheme.accent)
    yoloView.sliderConf.accessibilityLabel = "Detection confidence"
    for control in [yoloView.sliderConf, yoloView.labelSliderConf] {
      control.backgroundColor = UIColor(PatrolTheme.background).withAlphaComponent(0.8)
      control.layer.cornerRadius = 8
      control.clipsToBounds = true
    }
    yoloView.excludedClasses = ["longitudinal_crack", "transverse_crack"]
    // The tracker applies the slider's threshold, and needs weaker detections to keep known potholes alive.
    yoloView.fixedInferenceConfidence = 0.10
    yoloView.resultTransform = { [weak self] result in
      self?.steadied(result) ?? result
    }
    view.addSubview(yoloView)

    modelPicker.translatesAutoresizingMaskIntoConstraints = false
    modelPicker.overrideUserInterfaceStyle = .dark
    modelPicker.backgroundColor = UIColor(PatrolTheme.background).withAlphaComponent(0.8)
    modelPicker.selectedSegmentTintColor = UIColor(PatrolTheme.elevated)
    modelPicker.accessibilityLabel = "Detection model"
    modelPicker.selectedSegmentIndex = 0
    modelPicker.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.loadModel(at: self.modelPicker.selectedSegmentIndex)
      }, for: .valueChanged)
    view.addSubview(modelPicker)

    let closeButton = UIButton(configuration: .filled())
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.configuration?.image = UIImage(systemName: "xmark")
    closeButton.accessibilityLabel = "Exit Live Scan"
    closeButton.configuration?.cornerStyle = .capsule
    closeButton.configuration?.baseBackgroundColor = UIColor(PatrolTheme.background).withAlphaComponent(0.8)
    closeButton.configuration?.baseForegroundColor = UIColor(PatrolTheme.text)
    closeButton.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
    view.addSubview(closeButton)
    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      closeButton.centerYAnchor.constraint(equalTo: modelPicker.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    scanStatus.translatesAutoresizingMaskIntoConstraints = false
    scanStatus.font = UIFont.preferredFont(forTextStyle: .caption1)
    scanStatus.adjustsFontForContentSizeCategory = true
    scanStatus.numberOfLines = 0
    scanStatus.textAlignment = .center
    scanStatus.textColor = UIColor(PatrolTheme.text)
    scanStatus.backgroundColor = UIColor(PatrolTheme.background).withAlphaComponent(0.8)
    scanStatus.layer.cornerRadius = 12
    scanStatus.clipsToBounds = true
    view.addSubview(scanStatus)
    NSLayoutConstraint.activate([
      scanStatus.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      scanStatus.trailingAnchor.constraint(lessThanOrEqualTo: modelPicker.leadingAnchor, constant: -8),
      scanStatus.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      scanStatus.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      scanStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
    ])

    // The camera stops delivering frames in the background, so don't resume without the person choosing to.
    NotificationCenter.default.addObserver(
      self, selector: #selector(stopRunning), name: UIApplication.willResignActiveNotification,
      object: nil)

    button.translatesAutoresizingMaskIntoConstraints = false
    button.configuration?.cornerStyle = .capsule
    button.configuration?.baseForegroundColor = UIColor(PatrolTheme.text)
    button.configuration?.imagePadding = 8
    button.configuration?.contentInsets = NSDirectionalEdgeInsets(
      top: 16, leading: 40, bottom: 16, trailing: 40)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setRunning(!self.isRunning)
      }, for: .touchUpInside)
    view.addSubview(button)

    heightSlider.minimumValue = 0.5
    heightSlider.maximumValue = 3
    heightSlider.value = Float(cameraHeight)
    heightSlider.tintColor = UIColor(PatrolTheme.accent)
    heightSlider.accessibilityLabel = "Phone height above road in meters"
    heightSlider.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        let height = (Double(self.heightSlider.value) * 20).rounded() / 20  // Nearest 5 cm.
        guard height != self.cameraHeight else { return }
        self.cameraHeight = height
        self.showCameraHeight()
        self.sizeEstimator.reset()  // Earlier measurements used the old height.
      }, for: .valueChanged)
    heightLabel.textColor = yoloView.labelSliderConf.textColor
    heightLabel.font = yoloView.labelSliderConf.font
    for control in [heightSlider, heightLabel] {
      control.backgroundColor = UIColor(PatrolTheme.background).withAlphaComponent(0.8)
      control.layer.cornerRadius = 8
      control.clipsToBounds = true
    }
    showCameraHeight()
    view.addSubview(heightLabel)
    view.addSubview(heightSlider)

    NSLayoutConstraint.activate([
      modelPicker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      modelPicker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      modelPicker.heightAnchor.constraint(equalToConstant: 44),
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    loadModel(at: modelPicker.selectedSegmentIndex)
  }

  /// Places the height slider across from the confidence slider, which `YOLOView` positions by frame.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    yoloView.layoutIfNeeded()
    let confidenceSlider = yoloView.sliderConf.frame
    let trailingEdge = view.bounds.width - max(view.safeAreaInsets.right, 20)
    let width = min(confidenceSlider.width, trailingEdge - confidenceSlider.maxX - 16)
    heightSlider.frame = CGRect(
      x: trailingEdge - width, y: confidenceSlider.minY, width: width,
      height: confidenceSlider.height)
    heightLabel.frame = CGRect(
      x: trailingEdge - width, y: yoloView.labelSliderConf.frame.minY, width: width,
      height: yoloView.labelSliderConf.frame.height)
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

  /// The direction the camera faces, in degrees clockwise from north. While driving, the direction of travel is more
  /// reliable than a compass inside a car, and assumes the camera faces forward.
  private func cameraBearing(at fix: CLLocation) -> Double? {
    if fix.speed >= 3, fix.course >= 0, fix.courseAccuracy >= 0, fix.courseAccuracy <= 20 {
      return fix.course
    }
    guard hasCompassAttitude, let attitude = motion.deviceMotion?.attitude.rotationMatrix else {
      return nil
    }
    return CameraGeoPose.bearing(attitudeM31: attitude.m31, attitudeM32: attitude.m32)
  }

  /// Where the camera is right now, or `nil` without a recent, accurate GPS fix and a known direction.
  private func cameraPose() -> CameraGeoPose? {
    guard let fix = location.location, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 20
    else { return nil }
    let age = Date().timeIntervalSince(fix.timestamp)
    guard age >= 0, age <= 5, let bearing = cameraBearing(at: fix) else { return nil }

    // GPS updates about once a second, so carry a moving car forward to now.
    let traveled = fix.speed >= 3 && fix.course >= 0 ? fix.speed * min(age, 2) : 0
    let fixPose = CameraGeoPose(
      position: GeoCoordinate(
        latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
      bearing: fix.speed >= 3 && fix.course >= 0 ? fix.course : bearing)
    return CameraGeoPose(
      position: fixPose.coordinate(ahead: traveled, right: 0), bearing: bearing)
  }

  /// Adds this frame's measurements, then returns each tracked pothole's label text, such as
  /// "≈2.4 ft² · 3.2 m" above "40.42610, -86.87289". Area needs a measurement from within 5 m, so farther potholes
  /// show only their distance, and location needs a GPS fix.
  private func sizeLabels(for tracks: [TrackedDetection], in result: YOLOResult) -> [Int: String] {
    sizeEstimator.retain(ids: Set(tracks.map(\.id)))
    if let camera = groundCamera(for: result), let rotation = motion.deviceMotion?.rotationRate {
      let rotationRate = sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z)
      let pose = cameraPose()
      for track in tracks {
        guard let rect = track.measuredRect else { continue }
        sizeEstimator.add(
          id: track.id, rect: rect, imageSize: result.orig_shape, camera: camera,
          rotationRate: rotationRate, pose: pose)
      }
    }

    let squareFeetPerSquareMeter = 10.7639
    var labels = [Int: String]()
    for track in tracks {
      guard let size = sizeEstimator.size(id: track.id) else { continue }
      detectedPotholes[track.id] = DetectedPothole(
        width: size.width, length: size.length, area: size.area, coordinate: size.coordinate,
        lastSeen: Date())
      let distance = String(format: "%.1f m", size.distance)
      let measurements =
        size.area.map { String(format: "≈%.1f ft² · ", $0 * squareFeetPerSquareMeter) + distance }
        ?? distance
      labels[track.id] =
        size.coordinate.map {
          measurements + String(format: "\n%.5f, %.5f", $0.latitude, $0.longitude)
        } ?? measurements
    }
    return labels
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

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopRunning()
    yoloView.stop()
  }

  @objc private func stopRunning() {
    setRunning(false)
  }

  private func setRunning(_ running: Bool) {
    isRunning = running
    tracker.reset()
    sizeEstimator.reset()
    if running {
      motion.deviceMotionUpdateInterval = 1.0 / 30
      if CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical) {
        hasCompassAttitude = true
        motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical)
      } else {
        hasCompassAttitude = false
        motion.startDeviceMotionUpdates()
      }
    } else {
      motion.stopDeviceMotionUpdates()
    }
    yoloView.setInferenceFlag(ok: running)
    yoloView.showOverlays = running  // Turning this off also clears the boxes left on screen.
    button.configuration?.title = running ? "Stop" : "Start"
    button.configuration?.image = UIImage(systemName: running ? "stop.fill" : "play.fill")
    button.configuration?.baseBackgroundColor = UIColor(running ? PatrolTheme.elevated : PatrolTheme.accent)
    button.configuration?.baseForegroundColor = UIColor(running ? PatrolTheme.text : PatrolTheme.background)
    scanStatus.text = running ? "Scanning" : "Paused"
  }
}
