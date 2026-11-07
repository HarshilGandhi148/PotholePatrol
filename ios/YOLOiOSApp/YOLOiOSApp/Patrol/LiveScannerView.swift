import SwiftUI
import AVFoundation
import CoreLocation
import UltralyticsYOLO

@MainActor
final class ScannerViewModel: ObservableObject {
  @Published private(set) var running = false
  @Published var ready = false
  @Published var capturing = false
  @Published var modelStatus = "YOLO11n · not loaded"
  @Published var confidence: Double?
  @Published var candidateAvailable = false
  @Published var error: String?
  @Published var observation: PendingObservation?
  var captureAction: (() -> Void)?
  private(set) var lastCandidateAt: Date?
  private var previousBox: CGRect?
  private var consecutiveFrames = 0
  let location: LocationService
  let store: PatrolStore
  init(store: PatrolStore, location: LocationService) { self.store = store; self.location = location }

  func start() async {
    guard !capturing, store.pending == nil else { error = "Review or discard the pending observation before another capture."; return }
    let granted: Bool
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: granted = true
    case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
    default: granted = false
    }
    guard !Task.isCancelled else { return }
    guard granted else { error = "Camera access is denied. Enable it in iOS Settings."; return }
    guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
      error = "No usable rear camera. Live scanning requires a physical iPhone."; return
    }
    if let position = location.freshLocation(at: Date()), position.speed > 2 {
      error = "Scanning is unavailable while moving. Stop safely before using the camera."; return
    }
    error = nil; ready = false; candidateAvailable = false; confidence = nil
    previousBox = nil; consecutiveFrames = 0; lastCandidateAt = nil
    modelStatus = "Loading YOLO11n…"; UIApplication.shared.isIdleTimerDisabled = true; running = true; location.startScanning()
  }
  func stop() {
    UIApplication.shared.isIdleTimerDisabled = false
    running = false; ready = false; candidateAvailable = false; confidence = nil
    captureAction = nil; location.stop()
  }
  func received(_ result: YOLOResult) {
    guard running, !capturing else { return }
    guard let box = result.boxes.filter({ $0.cls.lowercased() == "pothole" }).max(by: { $0.conf < $1.conf }) else {
      consecutiveFrames = 0; previousBox = nil; candidateAvailable = false; confidence = nil; return
    }
    let now = Date()
    if let previous = previousBox, let time = lastCandidateAt,
      now.timeIntervalSince(time) < 0.7,
      hypot(Double(box.xywhn.midX - previous.midX), Double(box.xywhn.midY - previous.midY)) < 0.15 {
      consecutiveFrames += 1
    } else { consecutiveFrames = 1 }
    previousBox = box.xywhn; lastCandidateAt = now; confidence = Double(box.conf)
    candidateAvailable = consecutiveFrames >= 3
  }
  func capture() {
    guard running, ready, !capturing, candidateAvailable, let time = lastCandidateAt,
      Date().timeIntervalSince(time) < 1.0 else { error = "Keep a pothole visible for several frames, then capture."; return }
    if let position = location.freshLocation(at: Date()), position.speed > 2 { error = "Capture paused while moving."; stop(); return }
    captureAction?()
  }
  func captured(image: UIImage?, at time: Date, location: CLLocation?) {
    capturing = false
    guard let image else { error = "Still capture failed. Start scanning and try again."; stop(); return }
    do {
      let draft = PendingObservation(id: UUID(), capturedAt: time, lat: location?.coordinate.latitude,
        lng: location?.coordinate.longitude, accuracyMeters: location?.horizontalAccuracy,
        locationConfirmed: false, jpeg: try ObservationStorage.jpeg(from: image), backendURL: nil)
      do { try store.retain(draft) } catch { self.error = "Photo is in memory, but could not be saved on this device. Keep this review open and retry." }
      observation = draft; stop()
    } catch { self.error = error.localizedDescription; stop() }
  }
}

@MainActor
struct YOLOScannerSurface: UIViewControllerRepresentable {
  let model: ScannerViewModel
  func makeUIViewController(context: Context) -> RecordViewController { RecordViewController(model: model) }
  func updateUIViewController(_ controller: RecordViewController, context: Context) {}
  static func dismantleUIViewController(_ controller: RecordViewController, coordinator: ()) { controller.stopCamera() }
}

@MainActor
struct LiveScannerView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @StateObject private var model: ScannerViewModel
  @State private var stationary = false
  @State private var startRequest: UUID?
  @Environment(\.scenePhase) private var scenePhase
  init(store: PatrolStore, location: LocationService) {
    self.location = location
    _model = StateObject(wrappedValue: ScannerViewModel(store: store, location: location))
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Scan road damage").font(.title2.bold())
        Text("Scan only while stationary, from a safe location. Never operate the camera while driving.").font(.subheadline).foregroundStyle(.secondary)
        ZStack {
          RoundedRectangle(cornerRadius: 12).fill(Color.black)
          if model.running { YOLOScannerSurface(model: model).clipShape(RoundedRectangle(cornerRadius: 12)) }
          else { VStack(spacing: 12) { Image(systemName: "viewfinder").font(.largeTitle); Text("Camera paused"); Text("Start a scan to load YOLO11n").font(.caption) }.foregroundStyle(.white) }
          if model.running && !model.ready { ProgressView(model.modelStatus).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
        }.frame(height: 360)
        HStack { Label(model.modelStatus, systemImage: "cpu"); Spacer(); if let confidence = model.confidence { Text("\(Int(confidence * 100))% confidence").monospacedDigit() } }.font(.caption)
        Label(location.message, systemImage: "location").font(.caption).foregroundStyle(.secondary)
        if model.running {
          Text(model.candidateAvailable ? "Pothole candidate available. Confirm with a still photo." : "Looking for a pothole across nearby frames…").font(.subheadline)
          HStack {
            Button { model.stop() } label: { Label("Pause Scan", systemImage: "pause.fill") }.buttonStyle(.bordered).disabled(model.capturing)
            Button { model.capture() } label: { Label(model.capturing ? "Capturing…" : "Capture Pothole", systemImage: "camera.fill") }
              .buttonStyle(.borderedProminent).disabled(!model.ready || !model.candidateAvailable || model.capturing)
          }
        } else {
          Toggle("I am stationary and safely away from traffic", isOn: $stationary).font(.subheadline)
          Button { startRequest = UUID() } label: { Label("Start Scan", systemImage: "viewfinder") }
            .buttonStyle(.borderedProminent).disabled(!stationary || store.pending != nil || model.capturing)
        }
        if let pending = store.pending {
          Button { model.observation = pending } label: { Label("Review pending photo", systemImage: "photo") }.buttonStyle(.bordered)
        }
        if let error = model.error { ErrorNotice(text: error) }
        Button("Open iOS permission settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.caption)
        Text("Live inference runs on your iPhone. No frames are uploaded automatically. Scanning does not record video.").font(.caption).foregroundStyle(.secondary)
      }.padding()
    }
    .navigationTitle("Pothole Patrol").navigationBarTitleDisplayMode(.inline)
    .sheet(item: $model.observation) { observation in NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store) }
    .task(id: startRequest) { if startRequest != nil { await model.start() } }
    .onDisappear { startRequest = nil; model.stop() }
    .onReceive(location.$location) { position in
      if model.running, let position, abs(position.timestamp.timeIntervalSinceNow) < 15, position.speed > 2 {
        model.error = "Scanning paused while moving. Stop safely before using the camera."; model.stop()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification)) { _ in
      if model.running { model.error = "Camera session failed. Pause, check permissions, and start again."; model.stop() }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification)) { _ in
      if model.running { model.error = "Camera was interrupted. Start a new scan when it is available."; model.stop() }
    }
    .onChange(of: scenePhase) { phase in if phase != .active { model.stop() } }
  }
}
