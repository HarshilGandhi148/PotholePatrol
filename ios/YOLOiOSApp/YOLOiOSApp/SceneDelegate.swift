// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import Combine
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

/// Live Scan's camera preview with a model picker and one button: Record runs the selected bundled model with live
/// boxes, Stop pauses it.
final class RecordViewController: UIViewController {
  private let location: LocationService
  private let store: PatrolStore
  private let onClose: () -> Void
  private let reportGate = LiveReportGate()
  private let statusLabel = UILabel()
  private let saveButton = UIButton(configuration: .filled())
  /// A pothole the app is sure about, held until the person taps Save.
  private struct Capture {
    let trackID: Int
    var photo: UIImage
    /// How much of the frame the pothole fills in `photo`.
    var photoArea: CGFloat
    var time: Date
    var coordinate: GeoCoordinate
    var size: EstimatedSize
  }
  private var captures = [Capture]()
  /// The most potholes held at once, because each photo takes up memory until it's saved.
  private let maximumCaptures = 30
  private var storeObserver: AnyCancellable?
  /// Whether the motion attitude is referenced to north, so it can give the camera's compass direction.
  private var hasCompassAttitude = false

  init(location: LocationService, store: PatrolStore, onClose: @escaping () -> Void) {
    self.location = location
    self.store = store
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use init(location:store:onClose:)") }

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
    yoloView.labelFPS.alpha = 1
    yoloView.excludedClasses = ["longitudinal_crack", "transverse_crack"]
    // The tracker applies YOLOView's default threshold, and needs weaker detections to keep known potholes alive.
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

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textColor = .white
    statusLabel.backgroundColor = .black.withAlphaComponent(0.5)
    statusLabel.font = .preferredFont(forTextStyle: .caption1)
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    view.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.topAnchor.constraint(equalTo: modelPicker.bottomAnchor, constant: 44),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
    ])
    showReportStatus()
    // Reports keep going through after Stop, so this follows the store rather than the camera.
    storeObserver = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.showReportStatus()
    }

    let closeButton = UIButton(configuration: .filled())
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.configuration?.title = "Close"
    closeButton.configuration?.cornerStyle = .capsule
    closeButton.configuration?.baseBackgroundColor = .black.withAlphaComponent(0.5)
    closeButton.addAction(UIAction { [weak self] _ in self?.closeTapped() }, for: .touchUpInside)
    view.addSubview(closeButton)
    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      closeButton.centerYAnchor.constraint(equalTo: modelPicker.centerYAnchor),
    ])

    // The camera stops delivering frames in the background, so don't resume without the person choosing to.
    NotificationCenter.default.addObserver(
      self, selector: #selector(stopRunning), name: UIApplication.willResignActiveNotification,
      object: nil)

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

    saveButton.translatesAutoresizingMaskIntoConstraints = false
    saveButton.configuration?.cornerStyle = .capsule
    saveButton.configuration?.baseBackgroundColor = .systemBlue
    saveButton.addAction(UIAction { [weak self] _ in self?.saveCaptures() }, for: .touchUpInside)
    view.addSubview(saveButton)
    NSLayoutConstraint.activate([
      saveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      saveButton.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])
    showSaveCount()

    heightSlider.minimumValue = 0.5
    heightSlider.maximumValue = 3
    heightSlider.value = Float(cameraHeight)
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
    showCameraHeight()
    view.addSubview(heightLabel)
    view.addSubview(heightSlider)

    NSLayoutConstraint.activate([
      modelPicker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      modelPicker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    loadModel(at: modelPicker.selectedSegmentIndex)
  }

  /// Centers the height slider where `YOLOView` lays out its own hidden confidence slider, above the Record button.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    yoloView.layoutIfNeeded()
    let confidenceSlider = yoloView.sliderConf.frame
    let margin = max(view.safeAreaInsets.left, view.safeAreaInsets.right, 20)
    let width = min(view.bounds.width - margin * 2, 400)
    let left = (view.bounds.width - width) / 2
    heightSlider.frame = CGRect(
      x: left, y: confidenceSlider.minY, width: width, height: confidenceSlider.height)
    heightLabel.frame = CGRect(
      x: left, y: yoloView.labelSliderConf.frame.minY, width: width,
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

  /// Photographs any pothole that's now certain, using the frame it was detected in, and holds it for the Save button.
  /// While it stays in view, its photo is replaced whenever it's closer, and its size and location keep improving.
  private func captureCertainPotholes(_ tracks: [TrackedDetection], in result: YOLOResult) {
    if let photo = result.originalImage {
      for track in tracks {
        guard let size = sizeEstimator.size(id: track.id), let coordinate = size.coordinate else {
          continue
        }
        if let index = captures.firstIndex(where: { $0.trackID == track.id }) {
          captures[index].size = size
          captures[index].coordinate = coordinate
          if let area = reportGate.photoArea(of: track), area > captures[index].photoArea {
            captures[index].photo = photo
            captures[index].photoArea = area
            captures[index].time = Date()
          }
        } else if captures.count < maximumCaptures, reportGate.shouldReport(track, at: coordinate),
          let area = reportGate.photoArea(of: track)
        {
          reportGate.markReported(track, at: coordinate)
          captures.append(
            Capture(
              trackID: track.id, photo: photo, photoArea: area, time: Date(),
              coordinate: coordinate, size: size))
        }
      }
      showSaveCount()
    }
    // Keeping a frame is slow, so only ask for one while it could become a capture or a closer photo.
    let isFollowingCapture = tracks.contains { track in captures.contains { $0.trackID == track.id } }
    yoloView.capturesOriginalImage =
      isFollowingCapture || (captures.count < maximumCaptures && reportGate.wantsPhoto(of: tracks))
  }

  private func showSaveCount() {
    saveButton.configuration?.title = captures.isEmpty ? "Save" : "Save \(captures.count)"
    saveButton.isEnabled = !captures.isEmpty
  }

  /// Turns the held potholes into reports, which appear in My Reports and are sent to the backend.
  private func saveCaptures() {
    for capture in captures {
      store.reportLive(
        photo: capture.photo,
        coordinate: (capture.coordinate.latitude, capture.coordinate.longitude),
        capturedAt: capture.time, width: capture.size.width, length: capture.size.length,
        area: capture.size.area)
    }
    captures.removeAll()
    showSaveCount()
  }

  /// Unsaved potholes would be lost by closing, so ask first.
  private func closeTapped() {
    guard !captures.isEmpty else {
      onClose()
      return
    }
    let count = captures.count
    let alert = UIAlertController(
      title: count == 1 ? "Save this pothole?" : "Save these \(count) potholes?",
      message: "They'll be added to My Reports and sent to Pothole Patrol.",
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "Save", style: .default) { [weak self] _ in
        self?.saveCaptures()
        self?.onClose()
      })
    alert.addAction(
      UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.onClose() })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(alert, animated: true)
  }

  private func showReportStatus() {
    statusLabel.text = store.liveStatus.map { " \($0) " }
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
    captureCertainPotholes(tracks, in: result)
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
    button.configuration?.title = running ? "Stop" : "Record"
    button.configuration?.baseBackgroundColor = running ? .darkGray : .systemRed
  }
}
