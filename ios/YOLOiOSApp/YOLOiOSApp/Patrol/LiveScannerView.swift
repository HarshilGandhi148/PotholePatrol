import AVFoundation
import SwiftUI

/// Full-screen live detection using `RecordViewController`. Potholes are kept in memory only, and nothing is sent yet.
@MainActor
struct LiveScannerView: View {
  let location: LocationService
  @Environment(\.dismiss) private var dismiss
  @State private var cameraProblem: String?
  @State private var cameraReady = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if cameraReady {
        LiveCameraSurface(location: location) { dismiss() }.ignoresSafeArea()
      } else if let cameraProblem {
        VStack(spacing: 16) {
          ErrorNotice(text: cameraProblem)
          Button("Open iOS Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
          Button("Close") { dismiss() }.buttonStyle(PatrolPrimaryButton())
        }.padding()
      } else {
        ProgressView().tint(.white)
      }
    }
    .preferredColorScheme(.dark).tint(PatrolTheme.accent)
    .task { await prepareCamera() }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      OrientationLock.allowLandscape()
      location.startScanning()
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      OrientationLock.returnToPortrait()
      location.stop()
    }
  }

  private func prepareCamera() async {
    guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
      cameraProblem = "No usable rear camera. Live Scan requires a physical iPhone."
      return
    }
    let granted: Bool
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: granted = true
    case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
    default: granted = false
    }
    if granted { cameraReady = true } else { cameraProblem = "Camera access is denied. Enable it in iOS Settings." }
  }
}

@MainActor
private struct LiveCameraSurface: UIViewControllerRepresentable {
  let location: LocationService
  let close: () -> Void
  func makeUIViewController(context: Context) -> RecordViewController {
    RecordViewController(location: location, onClose: close)
  }
  func updateUIViewController(_ controller: RecordViewController, context: Context) {}
}
