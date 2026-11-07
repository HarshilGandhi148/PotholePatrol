import SwiftUI
import AVFoundation

@MainActor
struct PotholePatrolRootView: View {
  @StateObject private var store = PatrolStore()
  @StateObject private var location = LocationService()
  @State private var tab = 0
  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { ScanModesView(location: location) }.tabItem { Label("Scan", systemImage: "viewfinder") }.tag(0)
      NavigationStack { CitizenMapView(location: location, beginScan: { tab = 0 }) }.tabItem { Label("Map", systemImage: "map") }.tag(1)
      NavigationStack { MyReportsView(location: location) }.tabItem { Label("My Reports", systemImage: "tray.full") }.tag(2)
      NavigationStack { PatrolSettingsView(location: location) }.tabItem { Label("More", systemImage: "gearshape") }.tag(3)
    }
    .environmentObject(store).tint(Color(red: 0.12, green: 0.34, blue: 0.72))
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in store.resumeLiveReports() }
  }
}

/// The Scan tab's two modes: live detection, or a plain photo to report.
@MainActor
struct ScanModesView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @State private var showingLiveScan = false
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Button { showingLiveScan = true } label: {
          modeCard(
            title: "Live Scan", systemImage: "video.fill",
            detail: "See potholes with their estimated size and location live. The app photographs potholes it's confident about, and tapping Save adds them to My Reports and sends them to Pothole Patrol, including whatever else is in the photo. Mount your phone and press Record before you start driving, and save after you've parked. Never handle your phone while driving.")
        }
        NavigationLink { PhotoReportView(location: location) } label: {
          modeCard(
            title: "Report a Photo", systemImage: "camera.fill",
            detail: "Standing still? Take one photo of a pothole and report it.")
        }
      }.buttonStyle(.plain).padding()
    }
    .navigationTitle("Pothole Patrol").navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(isPresented: $showingLiveScan) { LiveScannerView(location: location, store: store) }
  }
  private func modeCard(title: String, systemImage: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage).font(.title3.bold())
      Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
    }
    .padding().frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
  }
}

@MainActor
struct PatrolSettingsView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @State private var endpoint = ""
  @State private var message: String?
  @State private var admin = false
  @State private var checking = false
  @State private var deleteCapture = false
  @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
  var body: some View {
    Form {
      Section("Backend connection") {
        TextField("https://your-backend", text: $endpoint).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Save HTTPS configuration") {
          do { try store.configure(endpoint); endpoint = store.baseURLString; message = "Backend saved on this phone." }
          catch { message = error.localizedDescription }
        }.disabled(store.uploading || store.loading)
        Button(checking ? "Checking…" : "Check connection · GET /health") {
          checking = true; Task { await store.checkHealth(); checking = false }
        }.disabled(!store.configured || checking)
        Text(store.health).font(.caption)
        if let message { Text(message).font(.caption) }
        if let error = store.error { ErrorNotice(text: error) }
        Text("Ask Sanyam for the current HTTPS URL. No URL or passcode is bundled in this app. A server change signs out that server's saved administrator session.").font(.caption).foregroundStyle(.secondary)
      }
      Section("Permissions") {
        LabeledContent("Camera", value: cameraStatus)
        LabeledContent("Location", value: locationStatus)
        Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        Text("Camera and location are requested only when needed. No continuous journey history is stored.").font(.caption).foregroundStyle(.secondary)
      }
      Section("Administration") {
        Button { admin = true } label: { Label("Administrator Sign In", systemImage: "lock.shield") }.disabled(!store.configured)
        Text("Server verification is required. Citizen screens contain no maintenance scores or editing controls.").font(.caption).foregroundStyle(.secondary)
      }
      Section("Local capture") {
        Text("One pending observation is retained until upload or discard. Uploaded reports retain only IDs on this phone.").font(.caption).foregroundStyle(.secondary)
        Button("Delete saved capture", role: .destructive) { deleteCapture = true }.disabled(store.uploading)
      }
      Section("Government reporting") {
        Text("Pending updated backend contract")
        Text("SeeClickFix integration has been discontinued. Captures are sent to Pothole Patrol only, never to a government agency.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .confirmationDialog("Delete the saved observation photo from this phone?", isPresented: $deleteCapture, titleVisibility: .visible) {
      Button("Delete saved capture", role: .destructive) { do { try store.discardPending(); message = "Local capture deleted." } catch { message = error.localizedDescription } }
    }
    .navigationTitle("Settings").onAppear { endpoint = store.baseURLString; cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video) }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video) }
    .sheet(isPresented: $admin) {
      if let api = (try? store.api) { AdminEntryView(api: api).environmentObject(store) }
    }
  }
  private var cameraStatus: String {
    switch cameraAuthorization { case .authorized: return "Allowed"; case .denied, .restricted: return "Denied"; default: return "Not requested" }
  }
  private var locationStatus: String {
    switch location.authorization { case .authorizedAlways, .authorizedWhenInUse: return "Allowed"; case .denied, .restricted: return "Denied"; default: return "Not requested" }
  }
}

struct StatusBadge: View {
  let status: PotholeStatus
  var body: some View { Text(status.title).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5).foregroundStyle(status.color).background(status.color.opacity(0.1), in: Capsule()) }
}
extension PotholeStatus {
  var color: Color { switch self { case .open: return .red; case .acknowledged: return .orange; case .fixed: return .green } }
}
struct ErrorNotice: View {
  let text: String
  var body: some View { Label(text, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }
}
struct PotholePhoto: View {
  let url: URL?
  var body: some View {
    Group {
      if let url, url.scheme?.lowercased() == "https" {
        BackendImage(url: url) { $0.resizable().scaledToFit() } loading: {
          ProgressView().frame(maxWidth: .infinity, minHeight: 140)
        } failed: { placeholder }
      } else { placeholder }
    }.frame(maxWidth: .infinity).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
  }
  private var placeholder: some View { Label("No photo available", systemImage: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140) }
}

struct PotholeThumbnail: View {
  let url: URL?
  var body: some View {
    Group {
      if let url, url.scheme?.lowercased() == "https" {
        BackendImage(url: url) { $0.resizable().scaledToFill() } loading: { placeholder } failed: { placeholder }
      } else { placeholder }
    }.frame(width: 46, height: 46).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 6))
  }
  private var placeholder: some View { Image(systemName: "photo").foregroundStyle(.secondary) }
}

/// Loads a photo from the backend, keeping recent ones in memory so lists don't reload them.
@MainActor
private struct BackendImage<Content: View, Loading: View, Failed: View>: View {
  private static var cache: NSCache<NSURL, UIImage> { BackendImageCache.shared }
  let url: URL
  @ViewBuilder let content: (Image) -> Content
  @ViewBuilder let loading: () -> Loading
  @ViewBuilder let failed: () -> Failed
  @State private var image: UIImage?
  @State private var didFail = false
  var body: some View {
    Group {
      if let image { content(Image(uiImage: image)) } else if didFail { failed() } else { loading() }
    }
    .task(id: url) {
      image = Self.cache.object(forKey: url as NSURL); didFail = false
      guard image == nil else { return }
      if let data = try? await PotholeAPI.photoData(at: url), let loaded = UIImage(data: data) {
        Self.cache.setObject(loaded, forKey: url as NSURL); image = loaded
      } else if !Task.isCancelled { didFail = true }
    }
  }
}

private enum BackendImageCache {
  static let shared = NSCache<NSURL, UIImage>()
}
