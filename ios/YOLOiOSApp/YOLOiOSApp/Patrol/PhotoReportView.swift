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
  @State private var gettingLocation = false

  /// Above this speed, in meters per second, the person isn't stationary.
  private let maximumSpeed = 2.0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        PatrolCard {
          Label("A photo. A location. A report.", systemImage: "camera").font(.headline)
          Text("Take a clear photo. Your location is added automatically, and you can correct it before you submit.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
        }
        PatrolCard {
        if let pending = store.pending {
          Label("Photo waiting to upload", systemImage: "tray.and.arrow.up").font(.headline).foregroundStyle(PatrolTheme.warning)
          Text("Review your saved photo before taking another.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Button { observation = pending } label: { Label("Review Photo", systemImage: "photo") }.buttonStyle(PatrolPrimaryButton())
        } else {
          Text("Before you capture").font(.headline)
          Text("Stay safely away from traffic.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Toggle("I am stationary and safely away from traffic", isOn: $stationary).font(.subheadline)
          Button { takePhoto() } label: { Label("Take Photo", systemImage: "camera.fill") }
            .buttonStyle(PatrolPrimaryButton()).disabled(!stationary || gettingLocation)
        }
        }
        if gettingLocation { ProgressView("Getting your location…") }
        Label(location.message, systemImage: "location").font(.caption).foregroundStyle(PatrolTheme.secondary)
        if let error { ErrorNotice(text: error) }
        Button("Open iOS permission settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }.font(.subheadline).frame(minHeight: 44)
      }.padding()
    }
    .patrolScreen().navigationTitle("Report a Photo").navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(isPresented: $showingCamera) {
      PhotoCamera { image in
        showingCamera = false
        captured(image)
      }.ignoresSafeArea()
    }
    // The review screen stops location updates when it closes, so start them again for the next photo.
    .sheet(item: $observation, onDismiss: { location.startScanning() }) { observation in
      NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store)
    }
    .onAppear { location.startScanning() }
    // This also fires while the camera or review screen covers this one, which still need location.
    .onDisappear { if !showingCamera && !gettingLocation && observation == nil { location.stop() } }
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
      showingCamera = true
    }
  }

  private func captured(_ image: UIImage?) {
    guard let image else { return }  // The person cancelled.
    let time = Date()
    gettingLocation = true
    Task {
      let position = await location.bestLocation(at: time, waitingUpTo: 8)
      gettingLocation = false
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
