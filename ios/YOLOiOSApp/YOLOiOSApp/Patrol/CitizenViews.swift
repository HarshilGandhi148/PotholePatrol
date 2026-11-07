import SwiftUI
import MapKit
import CoreLocation

extension Pothole {
  var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
  var validCoordinate: Bool { lat.isFinite && lng.isFinite && (-90...90).contains(lat) && (-180...180).contains(lng) }
}

enum PatrolMap {
  static var home: MKCoordinateRegion { MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.91, longitude: -86.06), span: MKCoordinateSpan(latitudeDelta: 0.20, longitudeDelta: 0.20)) }
  static func fitted(_ reports: [Pothole]) -> MKCoordinateRegion? {
    let valid = reports.filter(\.validCoordinate); guard let first = valid.first else { return nil }
    let minLat = valid.map(\.lat).min() ?? first.lat, maxLat = valid.map(\.lat).max() ?? first.lat
    let minLng = valid.map(\.lng).min() ?? first.lng, maxLng = valid.map(\.lng).max() ?? first.lng
    return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
      span: MKCoordinateSpan(latitudeDelta: min(180, max(0.01, (maxLat - minLat) * 1.3)), longitudeDelta: min(360, max(0.01, (maxLng - minLng) * 1.3))))
  }
  static func contains(_ report: Pothole, in region: MKCoordinateRegion) -> Bool {
    abs(report.lat - region.center.latitude) <= region.span.latitudeDelta / 2 && abs(report.lng - region.center.longitude) <= region.span.longitudeDelta / 2
  }
}

@MainActor
struct CitizenMapView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  let beginScan: () -> Void
  @State private var region = PatrolMap.home
  @State private var selected: Pothole?
  @State private var centerRequested = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        Spacer()
        Button("Show All Reports") { if let fitted = PatrolMap.fitted(store.reports) { region = fitted } }.disabled(store.reports.isEmpty)
      }.font(.subheadline).padding()
      Map(coordinateRegion: $region, annotationItems: store.reports.filter(\.validCoordinate)) { report in
        MapAnnotation(coordinate: report.coordinate) {
          Button { selected = report } label: {
            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(report.status.color).background(.white, in: Circle())
          }.accessibilityLabel("\(report.title), \(report.status.title)")
        }
      }.overlay(alignment: .bottomLeading) {
        HStack { ForEach(PotholeStatus.allCases) { status in Label(status.title, systemImage: "circle.fill").foregroundStyle(status.color) } }
          .font(.caption).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
      }
      if store.loading { ProgressView("Refreshing observations…").padding() }
      if let error = store.error { ErrorNotice(text: error).padding(.horizontal) }
      if !store.loading && store.error == nil && !store.reports.contains(where: { PatrolMap.contains($0, in: region) }) {
        VStack(spacing: 8) {
          Text("No Pothole Patrol observations in this area yet.").font(.subheadline).multilineTextAlignment(.center)
          Button("Begin scanning", action: beginScan).buttonStyle(.borderedProminent)
        }.padding()
      }
      Button { centerRequested = true; location.retry() } label: { Label("Center on my approximate area", systemImage: "location") }.font(.subheadline).padding(.vertical, 12)
    }
    .navigationTitle("Road Damage Map").navigationBarTitleDisplayMode(.inline)
    .task(id: store.revision) {
      await store.refresh()
      if location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways { centerRequested = true; location.retry() }
    }
    .onReceive(location.$location) { position in
      guard centerRequested, let position, position.horizontalAccuracy >= 0, abs(position.timestamp.timeIntervalSinceNow) < 20 else { return }
      region = MKCoordinateRegion(center: position.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)); centerRequested = false
    }
    .sheet(item: $selected) { report in NavigationStack { PotholeDetailView(id: report.id) }.environmentObject(store) }
  }
}

@MainActor
struct PotholeDetailView: View {
  @EnvironmentObject private var store: PatrolStore
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var detail: PotholeDetail?
  @State private var error: String?
  @State private var loading = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if loading { ProgressView("Loading report…") }
        if let error { ErrorNotice(text: error); Button("Retry") { Task { await load() } } }
        if let report = detail?.pothole {
          PotholePhoto(url: report.photoUrl)
          StatusBadge(status: report.status)
          Text(report.title).font(.title3.bold())
          Text("First reported \(report.firstSeen.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(.secondary)
          Text("\(report.lat, specifier: "%.5f"), \(report.lng, specifier: "%.5f")").font(.caption).monospacedDigit()
          GroupBox("Responsible agency") {
            VStack(alignment: .leading, spacing: 8) {
              Text(report.owner.isPublic ? (report.owner.agencyName ?? "Agency information unavailable") : "Responsible agency not yet verified.").font(.headline)
              Text(report.owner.reason).font(.subheadline)
              if report.owner.confidence != "high" { Text("Location or ownership may need review.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          AgencyReportSection(report: report, plan: detail?.sendPlan) { await load() }
          Text("Status is provided by the backend. A closed report does not establish independent repair verification.").font(.caption).foregroundStyle(.secondary)
        }
      }.padding()
    }.navigationTitle("Pothole details").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task { await load() }.refreshable { await load() }
  }
  private func load() async {
    loading = true; defer { loading = false }
    do { detail = try await store.api.pothole(id: id); error = nil } catch { self.error = error.localizedDescription }
  }
}

@MainActor
struct MyReportsView: View {
  @EnvironmentObject private var store: PatrolStore
  @ObservedObject var location: LocationService
  @State private var pending: PendingObservation?
  var body: some View {
    List {
      if let observation = store.pending {
        Section("Saved on this phone · not uploaded") {
          Button { pending = observation } label: { Label("Review captured photo", systemImage: "photo") }
          Text("Original capture time retained. Retry only after reviewing the photo and location.").font(.caption).foregroundStyle(.secondary)
        }
      }
      if !store.liveReports.isEmpty {
        Section("Saved from Live Scan") {
          if let problem = store.liveError { ErrorNotice(text: problem) }
          if store.liveWaiting > 0 { Button("Send \(store.liveWaiting) now") { store.sendLiveReportsNow() } }
          ForEach(store.liveReports.reversed()) { report in
            NavigationLink { LiveReportDetailView(id: report.id) } label: { LiveReportRow(report: report) }
              .swipeActions { Button("Delete", role: .destructive) { store.deleteLiveReport(id: report.id) } }
          }
        }
      }
      if store.loading { ProgressView("Refreshing your reports…") }
      if let error = store.error { ErrorNotice(text: error) }
      if store.missingReports > 0 { Text("\(store.missingReports) unavailable report IDs were removed from this phone.").font(.caption) }
      if store.myReports.isEmpty && store.liveReports.isEmpty && !store.loading {
        Text("No uploaded reports saved on this phone yet.").foregroundStyle(.secondary)
      }
      Section("Contributed from this phone") {
        // Reports saved from Live Scan are listed above, and lead to the same page.
        ForEach(store.myReports.filter { report in !store.liveReports.contains { $0.serverID == report.id } }) { report in
          NavigationLink { PotholeDetailView(id: report.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
              Text(report.title).font(.subheadline.weight(.semibold)); StatusBadge(status: report.status)
              Text(report.firstSeen.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
          }
          .swipeActions { Button("Delete", role: .destructive) { store.removeFromMyReports(id: report.id) } }
        }
      }
      Text("Only contributed pothole IDs are saved for this list. This is not a user account or a driving history.").font(.caption).foregroundStyle(.secondary)
    }
    .navigationTitle("My Reports").task(id: store.revision) { await store.refreshMyReports() }
    .refreshable { await store.refreshMyReports() }
    .sheet(item: $pending) { observation in NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store) }
  }
}
