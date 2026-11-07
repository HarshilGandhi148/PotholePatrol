import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

/// Report one pothole with a plain photo, taken while stationary. This mode doesn't run the detection model.
@MainActor
struct PhotoReportView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @State private var stationary = false
  @State private var showingCamera = false
  @State private var observation: PendingObservation?
  @State private var error: String?

  /// Above this speed, in meters per second, the person isn't stationary.
  private let maximumSpeed = 2.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Report a photo").font(.title2.bold())
        Text("Only take a photo while stationary and safely away from traffic.").font(.subheadline).foregroundStyle(.secondary)
        Label(location.message, systemImage: "location").font(.caption).foregroundStyle(.secondary)
        if let pending = store.pending {
          Text("You have a photo waiting. Review or discard it before taking another.").font(.subheadline)
          Button { observation = pending } label: { Label("Review pending photo", systemImage: "photo") }.buttonStyle(.borderedProminent)
        } else {
          Toggle("I am stationary and safely away from traffic", isOn: $stationary).font(.subheadline)
          Button { takePhoto() } label: { Label("Take Photo", systemImage: "camera.fill") }
            .buttonStyle(.borderedProminent).disabled(!stationary)
        }
        if let error { ErrorNotice(text: error) }
        Button("Open iOS permission settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }.font(.caption)
      }.padding()
    }
    .navigationTitle("Report a Photo").navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(isPresented: $showingCamera) {
      PhotoCamera { image in
        showingCamera = false
        captured(image)
      }.ignoresSafeArea()
    }
    .sheet(item: $observation) { observation in
      NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store)
    }
    .onAppear { location.retry() }
  }

  private func takePhoto() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      error = "No usable camera. Taking a photo requires a physical iPhone."
      return
    }
    if let position = location.freshLocation(at: Date()), position.speed > maximumSpeed {
      error = "You appear to be moving. Stop safely before taking a photo."
      stationary = false
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .denied, .restricted:
      error = "Camera access is denied. Enable it in iOS Settings."
    default:
      error = nil
      // A stationary phone gets no new location updates, so ask for a fresh position for this photo.
      location.retry()
      showingCamera = true
    }
  }

  private func captured(_ image: UIImage?) {
    guard let image else { return }  // The person cancelled.
    let time = Date()
    let position = location.freshLocation(at: time)
    do {
      let draft = PendingObservation(
        id: UUID(), capturedAt: time, lat: position?.coordinate.latitude, lng: position?.coordinate.longitude,
        accuracyMeters: position?.horizontalAccuracy, locationConfirmed: false,
        jpeg: try ObservationStorage.jpeg(from: image), backendURL: nil)
      do { try store.retain(draft) } catch {
        self.error = "Photo is in memory, but could not be saved on this device. Keep the review open and retry."
      }
      observation = draft
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// The standard iOS camera. Reports the photo, or `nil` if the person cancels.
private struct PhotoCamera: UIViewControllerRepresentable {
  let finish: (UIImage?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let finish: (UIImage?) -> Void
    init(finish: @escaping (UIImage?) -> Void) { self.finish = finish }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      finish(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      finish(nil)
    }
  }
}
