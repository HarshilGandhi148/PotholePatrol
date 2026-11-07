import CoreImage
import MapKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UltralyticsYOLO

/// Runs Live Scan's detection on a video from the person's photo library.
@MainActor
final class VideoScanModel: ObservableObject {
  enum Stage { case choosing, processing, finished }

  @Published private(set) var stage = Stage.choosing
  @Published private(set) var videoName: String?
  @Published private(set) var preparingVideo = false
  @Published private(set) var progress = 0.0
  @Published private(set) var preview: CGImage?
  @Published private(set) var boxes: [(id: Int, rect: CGRect, label: String)] = []
  @Published private(set) var potholes: [VideoPothole] = []
  @Published private(set) var savedCount = 0
  @Published var error: String?

  private var videoURL: URL?
  private var creationDate: Date?
  private var scan: Task<Void, Never>?

  deinit {
    if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
  }

  /// Copies the chosen video out of the photo library, which only lends it for a moment.
  func load(_ provider: NSItemProvider) {
    preparingVideo = true; error = nil
    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, failure in
      let copy = url.flatMap { source -> URL? in
        let destination = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        return (try? FileManager.default.copyItem(at: source, to: destination)) == nil ? nil : destination
      }
      let name = provider.suggestedName
      Task { @MainActor in
        guard let self else { return }
        self.preparingVideo = false
        if let copy {
          if let old = self.videoURL { try? FileManager.default.removeItem(at: old) }
          self.videoURL = copy; self.videoName = name ?? "Selected video"
        } else {
          self.error = failure?.localizedDescription ?? "That video couldn't be opened."
        }
      }
    }
  }

  func start(height: Double, tilt: Double) {
    guard let videoURL else { return }
    stage = .processing; progress = 0; potholes = []; boxes = []; savedCount = 0; error = nil
    UIApplication.shared.isIdleTimerDisabled = true
    scan = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        try await self?.run(url: videoURL, height: height, tilt: tilt)
      } catch {
        await self?.report(error)
      }
      await self?.finish()
    }
  }

  func stop() {
    scan?.cancel()
  }

  private func report(_ failure: Error) {
    error = "The video couldn't be processed: \(failure.localizedDescription)"
  }

  private func finish() {
    UIApplication.shared.isIdleTimerDisabled = false
    boxes = []
    stage = .finished
  }

  private nonisolated func run(url: URL, height: Double, tilt: Double) async throws {
    let predictor = try await Self.loadModel()
    // The tracker applies the threshold, and needs weaker detections to keep known potholes alive, as in Live Scan.
    predictor.setConfidenceThreshold(confidence: 0.10)
    predictor.drawsAnnotations = false
    let reader = try await VideoFrameReader(url: url)
    await setCreationDate(reader.creationDate)
    let scanner = VideoPotholeScanner(height: height, tiltDegrees: tilt)
    let context = CIContext()

    while !Task.isCancelled, let frame = reader.nextFrame() {
      // Autorelease each frame, or a long video's frames pile up in memory until the loop ends.
      let update = autoreleasepool { () -> (CGImage?, [(id: Int, rect: CGRect, label: String)], [VideoPothole]) in
        let result = predictor.predictOnImage(image: frame.image)
        let detections = result.boxes.map {
          TrackerDetection(rect: $0.xywhn, confidence: $0.conf, classIndex: $0.index, className: $0.cls)
        }
        let tracks = scanner.process(detections, in: frame.image, at: frame.time)
        let boxes = tracks.map { track in
          (id: track.id, rect: track.rect, label: Self.label(for: track, size: scanner.size(ofTrack: track.id)))
        }
        return (context.createCGImage(frame.image, from: frame.image.extent), boxes, scanner.potholes)
      }
      let progress = reader.duration > 0 ? min(frame.time / reader.duration, 1) : 0
      await show(preview: update.0, boxes: update.1, potholes: update.2, progress: progress)
    }
  }

  private nonisolated static func label(for track: TrackedDetection, size: EstimatedSize?) -> String {
    let score = String(format: "%@ %.0f", track.className, track.confidence * 100)
    guard let area = size?.area else { return score }
    return score + String(format: " · ≈%.1f ft²", area * 10.7639)
  }

  private nonisolated static func loadModel() async throws -> BasePredictor {
    guard let url = Bundle.main.url(forResource: "Models/Detect/pothole-yolo11n", withExtension: "mlpackage") else {
      throw PatrolError.message("The bundled pothole model is missing.")
    }
    return try await withCheckedThrowingContinuation { continuation in
      BasePredictor.create(for: .detect, modelURL: url) { continuation.resume(with: $0) }
    }
  }

  private func setCreationDate(_ date: Date?) {
    creationDate = date
  }

  private func show(
    preview: CGImage?, boxes: [(id: Int, rect: CGRect, label: String)], potholes: [VideoPothole], progress: Double
  ) {
    self.preview = preview; self.boxes = boxes; self.potholes = potholes; self.progress = progress
  }

  /// Turns the potholes found into reports, the same way Live Scan's Save button does.
  func save(to store: PatrolStore, at coordinate: CLLocationCoordinate2D) {
    let start = creationDate ?? Date()
    for pothole in potholes {
      store.reportLive(
        photo: UIImage(cgImage: pothole.photo), coordinate: (coordinate.latitude, coordinate.longitude),
        capturedAt: start.addingTimeInterval(pothole.time), width: pothole.size?.width,
        length: pothole.size?.length, area: pothole.size?.area)
    }
    savedCount = potholes.count
    potholes = []
  }

  func startOver() {
    stage = .choosing; preview = nil; potholes = []; savedCount = 0; progress = 0
  }
}

/// Choose a video and its location, watch it being processed, then save the potholes found.
@MainActor
struct VideoScanView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @StateObject private var model = VideoScanModel()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingPicker = false
  @State private var confirmLeave = false
  @State private var region = PatrolMap.home
  @AppStorage("videoCameraTilt") private var tilt = 40.0
  @AppStorage("cameraHeightMeters") private var height = 1.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        switch model.stage {
        case .choosing: chooseVideo
        case .processing: processing
        case .finished: results
        }
        if let error = model.error { ErrorNotice(text: error) }
      }.padding()
    }
    .patrolScreen().navigationTitle("Upload a Video").navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(model.stage != .choosing)
    .toolbar {
      if model.stage == .finished {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { if model.potholes.isEmpty { dismiss() } else { confirmLeave = true } }
        }
      }
    }
    .sheet(isPresented: $showingPicker) {
      VideoPicker { provider in
        showingPicker = false
        if let provider { model.load(provider) }
      }.ignoresSafeArea()
    }
    .confirmationDialog("Leave without saving these potholes?", isPresented: $confirmLeave, titleVisibility: .visible) {
      Button("Leave without saving", role: .destructive) { dismiss() }
    }
    .onAppear { location.retry() }
    .onReceive(location.$location) { position in
      // Start the map where the person is, once, until they've chosen a video.
      guard let position, model.videoName == nil, !centeredOnPerson else { return }
      centeredOnPerson = true
      region.center = position.coordinate
      region.span = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
    }
    // The model can't run in the background, so end the scan and keep what it found.
    .onChange(of: scenePhase) { phase in if phase != .active { model.stop() } }
    .onDisappear { model.stop() }
  }
  @State private var centeredOnPerson = false

  private var chooseVideo: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("1 · Video") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Pick a road video from your photos. It stays on this phone, and is only used to find potholes.")
            .font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          if let name = model.videoName { Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(PatrolTheme.success) }
          if model.preparingVideo { ProgressView("Opening video…") }
          Button { showingPicker = true } label: {
            Label(model.videoName == nil ? "Choose Video" : "Choose a Different Video", systemImage: "photo.on.rectangle")
          }.buttonStyle(.bordered).disabled(model.preparingVideo)
        }
      }
      GroupBox("2 · Where was it filmed?") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Move the map so the pin is on the road. Every pothole found gets this location.")
            .font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          ZStack {
            Map(coordinateRegion: $region)
            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(PatrolTheme.accent).allowsHitTesting(false)
          }.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 12))
          Text(String(format: "%.5f, %.5f", region.center.latitude, region.center.longitude))
            .font(.caption).monospacedDigit().foregroundStyle(PatrolTheme.secondary)
        }
      }
      GroupBox("3 · How was it filmed?") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Used only to estimate size. A video doesn't record these, so sizes are rough.")
            .font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Text(String(format: "Phone height %.2f m", height)).font(.subheadline)
          Slider(value: $height, in: 0.5...3, step: 0.05).accessibilityLabel("Phone height above road in meters")
          Text(String(format: "Camera tilted down %.0f°", tilt)).font(.subheadline)
          Slider(value: $tilt, in: 0...80, step: 1).accessibilityLabel("Camera tilt below level in degrees")
        }
      }
      Button { model.start(height: height, tilt: tilt) } label: { Label("Find Potholes", systemImage: "viewfinder") }
        .buttonStyle(PatrolPrimaryButton()).disabled(model.videoName == nil || model.preparingVideo)
    }
  }

  private var processing: some View {
    VStack(alignment: .leading, spacing: 12) {
      videoPreview
      ProgressView(value: model.progress) { Text("Finding potholes…").font(.subheadline) }
      Label("\(model.potholes.count) found so far", systemImage: "viewfinder").font(.subheadline)
      Button("Stop") { model.stop() }.buttonStyle(.bordered)
    }
  }

  private var videoPreview: some View {
    Group {
      if let preview = model.preview {
        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .overlay {
            GeometryReader { geometry in
              ForEach(model.boxes, id: \.id) { box in
                VideoBoxOverlay(box: box.rect, label: box.label, size: geometry.size)
              }
            }
          }
          .frame(maxHeight: 420).frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else {
        ProgressView("Loading the model…").frame(maxWidth: .infinity, minHeight: 240)
      }
    }
  }

  private var results: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.savedCount > 0 {
        Label(model.savedCount == 1 ? "Saved 1 pothole" : "Saved \(model.savedCount) potholes", systemImage: "checkmark.circle.fill")
          .font(.headline).foregroundStyle(PatrolTheme.success)
        Text("They're in My Reports, and are being sent to Pothole Patrol.").font(.subheadline)
      } else if model.potholes.isEmpty {
        Text("No potholes found").font(.headline)
        Text("Try a video that shows the road closer up, with potholes staying in view for at least a second.")
          .font(.subheadline).foregroundStyle(PatrolTheme.secondary)
      } else {
        Text(model.potholes.count == 1 ? "1 pothole found" : "\(model.potholes.count) potholes found").font(.headline)
        ForEach(model.potholes, id: \.id) { pothole in
          PatrolCard {
            Image(decorative: pothole.photo, scale: 1).resizable().scaledToFit()
              .frame(maxWidth: .infinity, maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(String(format: "%.1f s into the video", pothole.time)).font(.caption).foregroundStyle(PatrolTheme.secondary)
            if let area = pothole.size?.area {
              Text(String(format: "Estimated area ≈%.1f ft²", area * 10.7639)).font(.subheadline)
            }
          }
        }
        Button {
          model.save(to: store, at: region.center)
        } label: { Label("Save \(model.potholes.count)", systemImage: "square.and.arrow.down") }
          .buttonStyle(PatrolPrimaryButton())
        Text("Saving adds them to My Reports and sends them to Pothole Patrol, including whatever else is in the photos.")
          .font(.caption).foregroundStyle(PatrolTheme.secondary)
      }
      if model.potholes.isEmpty {
        Button("Scan Another Video") { model.startOver() }.buttonStyle(.bordered)
      }
    }
  }
}

private struct VideoBoxOverlay: View {
  let box: CGRect
  let label: String
  let size: CGSize
  var body: some View {
    let frame = CGRect(
      x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width,
      height: box.height * size.height)
    ZStack(alignment: .topLeading) {
      Rectangle().strokeBorder(PatrolTheme.accent, lineWidth: 2)
      Text(label).font(.caption2.weight(.semibold)).lineLimit(1).padding(.horizontal, 4)
        .foregroundStyle(PatrolTheme.background).background(PatrolTheme.accent)
    }
    .frame(width: frame.width, height: frame.height)
    .position(x: frame.midX, y: frame.midY)
  }
}

/// The system photo picker, showing only videos. It doesn't need photo library permission.
private struct VideoPicker: UIViewControllerRepresentable {
  let finish: (NSItemProvider?) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.filter = .videos
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    private let finish: (NSItemProvider?) -> Void
    init(finish: @escaping (NSItemProvider?) -> Void) { self.finish = finish }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      finish(results.first?.itemProvider)
    }
  }
}
