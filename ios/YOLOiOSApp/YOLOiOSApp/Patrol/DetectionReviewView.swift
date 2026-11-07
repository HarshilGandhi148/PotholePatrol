import SwiftUI
import MapKit
import CoreLocation

@MainActor
struct DetectionReviewView: View {
  @EnvironmentObject private var store: PatrolStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var location: LocationService
  @State private var draft: PendingObservation
  @State private var latitude: String
  @State private var longitude: String
  @State private var photoConfirmed = false
  @State private var confirmed = false
  @State private var error: String?
  @State private var discard = false
  @State private var region: MKCoordinateRegion
  init(observation: PendingObservation, location: LocationService) {
    self.location = location; _draft = State(initialValue: observation)
    _latitude = State(initialValue: observation.lat.map { String($0) } ?? "")
    _longitude = State(initialValue: observation.lng.map { String($0) } ?? "")
    _region = State(initialValue: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: observation.lat ?? 39.957, longitude: observation.lng ?? -86.0145), span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let result = store.uploadResult {
          Label(result.isNew ? "New observation received" : "Merged with an existing pothole", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
          Text(result.pothole.title)
          StatusBadge(status: result.pothole.status)
          Text("Saved to My Reports. The public map uses the backend's current record.").font(.subheadline)
          if !result.pothole.owner.isPublic { Text("Responsible agency not yet verified.").foregroundStyle(.secondary) }
          Text("Government reporting is pending an updated contract. No agency has been contacted.").font(.caption).foregroundStyle(.secondary)
          NavigationLink("View public report") { PotholeDetailView(id: result.potholeId) }
          Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        } else {
          if let image = UIImage(data: draft.jpeg) { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8)) }
          Text("User-initiated still exported by the YOLO SDK. It may include detection overlays. Check that this photo shows the pothole you intend to report.").font(.caption).foregroundStyle(.secondary)
          Text("Captured \(draft.capturedAt.formatted(date: .abbreviated, time: .standard))").font(.caption)
          Toggle("This photo shows the pothole I want to report", isOn: $photoConfirmed)
          GroupBox("Confirm location") {
            VStack(alignment: .leading, spacing: 12) {
              Text(draft.lat == nil ? "No accurate GPS at capture. Choose the actual pothole position." : "Approximate capture GPS. Correct the position if necessary.").font(.subheadline)
              if let accuracy = draft.accuracyMeters { Text("Capture GPS accuracy: ±\(Int(accuracy)) m").font(.caption) }
              HStack {
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
              }.textFieldStyle(.roundedBorder)
              ZStack { Map(coordinateRegion: $region); Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.blue).allowsHitTesting(false) }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8))
              Button("Use map center") { latitude = String(region.center.latitude); longitude = String(region.center.longitude); confirmed = false }
              Button("Retry GPS") { location.retry() }
              Text(location.message).font(.caption).foregroundStyle(.secondary)
              Button("Use fresh GPS at my current position") {
                guard let position = location.freshLocation(at: Date()) else { error = "No recent GPS within 20 m. Retry or set the coordinates manually."; return }
                latitude = String(position.coordinate.latitude); longitude = String(position.coordinate.longitude)
                region.center = position.coordinate; confirmed = false
              }
              Text("A later GPS reading is a manual correction, not the original capture location. Only use it if you are still at this pothole.").font(.caption).foregroundStyle(.secondary)
              Toggle("I confirmed the pothole's location", isOn: $confirmed)
            }
          }
          Text("Uploads one JPEG and the confirmed coordinates/time to Pothole Patrol. No severity or repair priority is inferred.").font(.caption).foregroundStyle(.secondary)
          if let error { ErrorNotice(text: error) }
          if let error = store.error { ErrorNotice(text: error) }
          HStack {
            Button("Discard", role: .destructive) { discard = true }.disabled(store.uploading)
            Spacer()
            Button { saveAndUpload() } label: { if store.uploading { ProgressView() }; Text(store.uploading ? "Uploading…" : "Confirm & Upload") }
              .buttonStyle(.borderedProminent).disabled(!photoConfirmed || !confirmed || store.uploading || !store.configured)
          }
          Button("Save for later") { do { try updatePending(requireLocation: false); dismiss() } catch { self.error = error.localizedDescription } }.disabled(store.uploading)
          if !store.configured { Text("Configure the HTTPS backend in More → Settings before uploading. This photo can be saved on your phone meanwhile.").font(.caption).foregroundStyle(.secondary) }
        }
      }.padding()
    }
    .navigationTitle("Review observation").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(store.uploading) } }
    .interactiveDismissDisabled(store.uploading)
    .confirmationDialog("Discard this captured photo?", isPresented: $discard, titleVisibility: .visible) {
      Button("Discard photo", role: .destructive) { do { try store.discardPending(); dismiss() } catch { self.error = error.localizedDescription } }
    }
    .onChange(of: latitude) { _ in confirmed = false }
    .onChange(of: longitude) { _ in confirmed = false }
    .onDisappear { location.stop() }
  }
  private func updatePending(requireLocation: Bool) throws {
    let lat = Double(latitude), lng = Double(longitude)
    if requireLocation {
      guard let lat, let lng, lat.isFinite, lng.isFinite, (-90...90).contains(lat), (-180...180).contains(lng), confirmed, photoConfirmed else {
        throw PatrolError.message("Review the photo and confirm valid coordinates.")
      }
    }
    draft.lat = lat; draft.lng = lng; draft.locationConfirmed = confirmed && photoConfirmed
    try store.retain(draft)
  }
  private func saveAndUpload() {
    do { try updatePending(requireLocation: true); Task { await store.upload() } }
    catch { self.error = error.localizedDescription }
  }
}
