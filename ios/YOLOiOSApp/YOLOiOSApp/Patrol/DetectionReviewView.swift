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
          PatrolCard {
          Label(result.isNew ? "Report received" : "Added to an existing report", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(PatrolTheme.success)
          Text(result.pothole.title)
          StatusBadge(status: result.pothole.status)
          Text("Saved to My Reports. The public map uses the backend's current record.").font(.subheadline)
          if !result.pothole.owner.isPublic { Text("Responsible agency not yet verified.").foregroundStyle(PatrolTheme.secondary) }
          if result.askToSend, let agency = result.sendPlan?.agencyName {
            Text("Ready to report to \(agency). Nothing has been sent yet.").font(.subheadline)
            NavigationLink("Review and report") { PotholeDetailView(id: result.potholeId) }.buttonStyle(PatrolPrimaryButton())
          } else {
            NavigationLink("View public report") { PotholeDetailView(id: result.potholeId) }
          }
          Button("Done") { dismiss() }.buttonStyle(PatrolPrimaryButton())
          }
        } else {
          PatrolCard {
          Label("1 · Photo", systemImage: "photo").font(.headline)
          if let image = UIImage(data: draft.jpeg) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 12)) }
          Text("Captured \(draft.capturedAt.formatted(date: .abbreviated, time: .standard))").font(.caption)
          Toggle("This photo shows the pothole I want to report", isOn: $photoConfirmed)
          }
          GroupBox("2 · Location") {
            VStack(alignment: .leading, spacing: 12) {
              Text(draft.lat == nil ? "No accurate GPS at capture. Choose the actual pothole position." : "Approximate capture GPS. Correct the position if necessary.").font(.subheadline)
              if let accuracy = draft.accuracyMeters { Text("Capture GPS accuracy: ±\(Int(accuracy)) m").font(.caption) }
              VStack(alignment: .leading, spacing: 8) {
                Text("Coordinates").font(.caption).foregroundStyle(PatrolTheme.secondary)
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation).accessibilityLabel("Latitude")
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation).accessibilityLabel("Longitude")
              }.textFieldStyle(.roundedBorder)
              ZStack { Map(coordinateRegion: $region); Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(PatrolTheme.accent).allowsHitTesting(false) }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Pothole location map. Move the map, then choose Use Map Center.")
              Button("Use Map Center") { latitude = String(region.center.latitude); longitude = String(region.center.longitude); confirmed = false }.frame(minHeight: 44)
              Button("Retry GPS") { location.retry() }.frame(minHeight: 44)
              Text(location.message).font(.caption).foregroundStyle(PatrolTheme.secondary)
              Button("Use fresh GPS at my current position") {
                guard let position = location.freshLocation(at: Date()) else { error = "No recent GPS within 20 m. Retry or set the coordinates manually."; return }
                latitude = String(position.coordinate.latitude); longitude = String(position.coordinate.longitude)
                region.center = position.coordinate; confirmed = false
              }.frame(minHeight: 44)
              Text("A later GPS reading is a manual correction, not the original capture location. Only use it if you are still at this pothole.").font(.caption).foregroundStyle(PatrolTheme.secondary)
              Toggle("I confirmed the pothole's location", isOn: $confirmed)
            }
          }
          PatrolCard {
          Text("3 · Submit").font(.headline)
          Text("Send this photo and confirmed location to Pothole Patrol.").font(.caption).foregroundStyle(PatrolTheme.secondary)
          if let error { ErrorNotice(text: error) }
          if let error = store.error { ErrorNotice(text: error) }
          Button { saveAndUpload() } label: {
            HStack { if store.uploading { ProgressView().tint(PatrolTheme.secondary) }; Text(store.uploading ? "Uploading…" : "Submit Report") }
          }.buttonStyle(PatrolPrimaryButton()).disabled(!photoConfirmed || !confirmed || store.uploading || !store.configured)
          HStack {
            Button("Save for later") { do { try updatePending(requireLocation: false); dismiss() } catch { self.error = error.localizedDescription } }.disabled(store.uploading)
            Spacer()
            Button("Discard", role: .destructive) { discard = true }.disabled(store.uploading)
          }.font(.subheadline).frame(minHeight: 44)
          if !store.configured { Text("Add a backend in Settings to submit. You can save this photo for later.").font(.caption).foregroundStyle(PatrolTheme.secondary) }
          }
        }
      }.padding()
    }
    .patrolScreen().navigationTitle("Review Report").navigationBarTitleDisplayMode(.inline)
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
