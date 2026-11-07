import SwiftUI
import AVFoundation

/// Shared presentation only. Service and capture state stay with their existing owners.
enum PatrolTheme {
  static let background = Color(red: 13/255, green: 17/255, blue: 23/255)
  static let surface = Color(red: 22/255, green: 29/255, blue: 39/255)
  static let elevated = Color(red: 32/255, green: 42/255, blue: 54/255)
  static let text = Color(red: 245/255, green: 247/255, blue: 250/255)
  static let secondary = Color(red: 152/255, green: 164/255, blue: 179/255)
  static let accent = Color(red: 76/255, green: 141/255, blue: 255/255)
  static let success = Color(red: 69/255, green: 194/255, blue: 138/255)
  static let warning = Color(red: 229/255, green: 174/255, blue: 87/255)
  static let error = Color(red: 227/255, green: 107/255, blue: 113/255)
}

struct PatrolCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content }
      .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(PatrolTheme.surface, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PatrolTheme.secondary.opacity(0.12)))
  }
}

struct PatrolPrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
      .foregroundStyle(enabled ? PatrolTheme.background : PatrolTheme.secondary)
      .background(enabled ? PatrolTheme.accent : PatrolTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
      .opacity(configuration.isPressed ? 0.75 : (enabled ? 1 : 0.5))
  }
}

struct PatrolEmptyState: View {
  let title: String
  let symbol: String
  let actionTitle: String
  let action: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.title2).foregroundStyle(PatrolTheme.secondary).accessibilityHidden(true)
      Text(title).font(.headline).multilineTextAlignment(.center)
      Button(actionTitle, action: action).buttonStyle(PatrolPrimaryButton())
    }.padding(20).frame(maxWidth: .infinity)
  }
}

struct PatrolMetricCard: View {
  let title: String
  let value: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(value, format: .number).font(.title2.weight(.semibold).monospacedDigit())
      Text(title).font(.caption).foregroundStyle(PatrolTheme.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(PatrolTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .combine)
  }
}

struct PatrolGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    PatrolCard {
      configuration.label.font(.subheadline.weight(.semibold))
      configuration.content.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension View {
  func patrolScreen() -> some View {
    self.scrollContentBackground(.hidden).background(PatrolTheme.background)
      .foregroundStyle(PatrolTheme.text).tint(PatrolTheme.accent)
      .groupBoxStyle(PatrolGroupBoxStyle())
      .toolbar(.visible, for: .navigationBar)
      .toolbarBackground(PatrolTheme.background, for: .navigationBar, .tabBar)
      .toolbarBackground(.visible, for: .navigationBar, .tabBar)
  }
}

@MainActor
struct PotholePatrolRootView: View {
  @StateObject private var store = PatrolStore()
  @StateObject private var location = LocationService()
  @State private var tab = 0
  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { ScanModesView(location: location, exploreMap: { tab = 1 }) }.tabItem { Label("Scan", systemImage: "viewfinder") }.tag(0)
      NavigationStack { CitizenMapView(location: location, beginScan: { tab = 0 }) }.tabItem { Label("Map", systemImage: "map") }.tag(1)
      NavigationStack { MyReportsView(location: location, beginScan: { tab = 0 }) }.tabItem { Label("My Reports", systemImage: "tray.full") }.tag(2)
      NavigationStack { PatrolSettingsView(location: location) }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
    }
    .environmentObject(store).tint(PatrolTheme.accent).preferredColorScheme(.dark)
    .groupBoxStyle(PatrolGroupBoxStyle())
    .toolbarBackground(PatrolTheme.background, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in store.resumeLiveReports() }
  }
}

/// The Scan tab's two modes: live detection, or a plain photo to report.
@MainActor
struct ScanModesView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  let exploreMap: () -> Void
  @State private var showingLiveScan = false
  @State private var pending: PendingObservation?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Pothole Patrol").font(.title2.weight(.semibold))
          Text("Smarter road reporting.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
        }.padding(.vertical, 4)
        PatrolCard {
          HStack {
            Image(systemName: "viewfinder").font(.title2).foregroundStyle(PatrolTheme.accent)
            Spacer()
            Label("On-device AI", systemImage: "cpu").font(.caption).foregroundStyle(PatrolTheme.secondary)
          }
          Text("Live Scan").font(.title3.weight(.semibold))
          Text("Detect potholes with live size and location estimates. The app photographs potholes it's confident about. Tapping Save adds them to My Reports and sends them to Pothole Patrol, including whatever else is in the photo.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Button { showingLiveScan = true } label: { Label("Start Scanning", systemImage: "viewfinder") }
            .buttonStyle(PatrolPrimaryButton())
          Text("Mount your phone and tap Start before driving, and save after you've parked. Never handle it while driving.").font(.caption).foregroundStyle(PatrolTheme.secondary)
        }
        NavigationLink { PhotoReportView(location: location) } label: {
          actionRow("Report a Photo", symbol: "camera", detail: "Capture a pothole manually.")
        }
        Button(action: exploreMap) { actionRow("Explore Map", symbol: "map", detail: "View reported road damage.") }
        if let observation = store.pending {
          Button { pending = observation } label: {
            actionRow("Report waiting to upload", symbol: "tray.and.arrow.up", detail: "Review your saved photo and location.")
          }
        }
        PatrolCard {
          Label(store.configured ? "Backend · \(store.health)" : "Set up your backend in Settings", systemImage: "network")
            .font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          if !store.myReports.isEmpty {
            Text("\(store.myReports.count) reports loaded from this device").font(.caption).foregroundStyle(PatrolTheme.secondary)
          }
        }
      }.buttonStyle(.plain).padding()
    }
    .patrolScreen().toolbar(.hidden, for: .navigationBar)
    .fullScreenCover(isPresented: $showingLiveScan) { LiveScannerView(location: location, store: store) }
    .sheet(item: $pending) { observation in
      NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store)
    }
  }
  private func actionRow(_ title: String, symbol: String, detail: String) -> some View {
    PatrolCard {
      HStack(spacing: 12) {
        Image(systemName: symbol).font(.title3).foregroundStyle(PatrolTheme.accent).frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PatrolTheme.text)
          Text(detail).font(.caption).foregroundStyle(PatrolTheme.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PatrolTheme.secondary)
      }.multilineTextAlignment(.leading)
    }
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
        Button("Save Connection") {
          do { try store.configure(endpoint); endpoint = store.baseURLString; message = "Backend saved on this phone." }
          catch { message = error.localizedDescription }
        }.disabled(store.uploading || store.loading)
        Button(checking ? "Checking…" : "Check Connection") {
          checking = true; Task { await store.checkHealth(); checking = false }
        }.disabled(!store.configured || checking)
        Text(store.health).font(.caption)
        if let message { Text(message).font(.caption) }
        if let error = store.error { ErrorNotice(text: error) }
        DisclosureGroup("Connection details") {
          Text("Use the team's current HTTPS URL. Changing servers signs out the saved administrator session. Connection checks use GET /health.").font(.caption).foregroundStyle(PatrolTheme.secondary)
        }
      }.listRowBackground(PatrolTheme.surface)
      Section("Permissions") {
        LabeledContent("Camera", value: cameraStatus)
        LabeledContent("Location", value: locationStatus)
        Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        Text("Camera and location are requested only when needed. No continuous journey history is stored.").font(.caption).foregroundStyle(PatrolTheme.secondary)
      }.listRowBackground(PatrolTheme.surface)
      Section("Administrator Access") {
        Button { admin = true } label: { Label("Administrator Sign In", systemImage: "lock.shield") }.disabled(!store.configured)
        Text(store.configured ? "Secure access to maintenance operations." : "Save a backend connection to sign in.").font(.caption).foregroundStyle(PatrolTheme.secondary)
      }.listRowBackground(PatrolTheme.surface)
      Section("Local Data") {
        Text(store.pending == nil ? "No pending photo. Submitted reports are stored as IDs." : "One photo saved on this phone, waiting to upload.").font(.caption).foregroundStyle(PatrolTheme.secondary)
        Button("Delete saved capture", role: .destructive) { deleteCapture = true }.disabled(store.uploading)
      }.listRowBackground(PatrolTheme.surface)
      Section("About") {
        Label("Pothole Patrol", systemImage: "viewfinder")
        Text("On-device pothole detection · YOLO11n").font(.caption).foregroundStyle(PatrolTheme.secondary)
        DisclosureGroup("Government reporting") {
          Text("Agency handoff is pending. Reports are sent to Pothole Patrol only. Indianapolis and Fishers ownership coverage is not yet verified.").font(.caption).foregroundStyle(PatrolTheme.secondary)
        }
      }.listRowBackground(PatrolTheme.surface)
    }
    .patrolScreen().navigationBarTitleDisplayMode(.inline)
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
  var body: some View { Label(status.title, systemImage: "circle.fill").font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(status.color).background(status.color.opacity(0.12), in: Capsule()).accessibilityLabel("Status: \(status.title)") }
}
extension PotholeStatus {
  var color: Color { switch self { case .open: return PatrolTheme.error; case .acknowledged: return PatrolTheme.warning; case .fixed: return PatrolTheme.success } }
}
struct ErrorNotice: View {
  let text: String
  var body: some View { Label(text, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(PatrolTheme.error).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(PatrolTheme.error.opacity(0.1), in: RoundedRectangle(cornerRadius: 12)) }
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
    }.frame(maxWidth: .infinity).frame(maxHeight: 240).background(PatrolTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
  }
  private var placeholder: some View { Label("No photo available", systemImage: "photo").foregroundStyle(PatrolTheme.secondary).frame(maxWidth: .infinity, minHeight: 140) }
}

struct PotholeThumbnail: View {
  let url: URL?
  var body: some View {
    Group {
      if let url, url.scheme?.lowercased() == "https" {
        BackendImage(url: url) { $0.resizable().scaledToFill() } loading: { placeholder } failed: { placeholder }
      } else { placeholder }
    }.frame(width: 48, height: 48).background(PatrolTheme.elevated).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
  }
  private var placeholder: some View { Image(systemName: "photo").foregroundStyle(PatrolTheme.secondary) }
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
