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
    ZStack(alignment: .topTrailing) {
      Map(coordinateRegion: $region, annotationItems: store.reports.filter(\.validCoordinate)) { report in
        MapAnnotation(coordinate: report.coordinate) {
          Button { selected = report } label: {
            PatrolMapMarker(status: report.status)
          }.accessibilityLabel("\(report.title), \(report.status.title)")
        }
      }
      VStack(spacing: 8) {
        Button { centerRequested = true; location.retry() } label: { Label("Current location", systemImage: "location") }
        Button { Task { await store.refresh() } } label: { Label("Refresh reports", systemImage: "arrow.clockwise") }.disabled(store.loading)
        Button { if let fitted = PatrolMap.fitted(store.reports) { region = fitted } } label: { Label("Show all reports", systemImage: "arrow.up.left.and.arrow.down.right") }.disabled(store.reports.isEmpty)
      }.labelStyle(.iconOnly).buttonStyle(PatrolMapButton()).padding(16)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) {
        if store.loading { ProgressView("Refreshing reports…").font(.caption).padding(12).background(.regularMaterial, in: Capsule()) }
        if let error = store.error { ErrorNotice(text: error).background(PatrolTheme.background, in: RoundedRectangle(cornerRadius: 12)) }
        if centerRequested { Text(location.message).font(.caption).padding(10).background(.regularMaterial, in: Capsule()) }
        if !store.loading && store.error == nil && !store.reports.contains(where: { PatrolMap.contains($0, in: region) }) {
          VStack(spacing: 8) {
            Text("No road reports in this area yet.").font(.subheadline.weight(.medium))
            Button("Start a Scan", action: beginScan).frame(minHeight: 44)
          }.frame(maxWidth: .infinity).padding(12).background(PatrolTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { ForEach(PotholeStatus.allCases) { StatusBadge(status: $0) } }
          VStack(spacing: 4) { ForEach(PotholeStatus.allCases) { StatusBadge(status: $0) } }
        }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(16)
    }
    .patrolScreen().navigationTitle("Road Map").navigationBarTitleDisplayMode(.inline)
    .task(id: store.revision) {
      await store.refresh()
      if location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways { centerRequested = true; location.retry() }
    }
    .onReceive(location.$location) { position in
      guard centerRequested, let position, position.horizontalAccuracy >= 0, abs(position.timestamp.timeIntervalSinceNow) < 20 else { return }
      region = MKCoordinateRegion(center: position.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)); centerRequested = false
    }
    .sheet(item: $selected) { report in
      NavigationStack { PotholeDetailView(id: report.id) }.environmentObject(store)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
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
          StatusBadge(status: report.status)
          Text(report.title).font(.title3.bold())
          if let road = report.roadName { Text(road).font(.subheadline).foregroundStyle(PatrolTheme.secondary) }
          PotholePhoto(url: report.photoUrl)
          Text("First reported \(report.firstSeen.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Text("\(report.lat, specifier: "%.5f"), \(report.lng, specifier: "%.5f")").font(.caption).monospacedDigit()
          GroupBox("Responsible agency") {
            VStack(alignment: .leading, spacing: 8) {
              Text(report.owner.isPublic ? (report.owner.agencyName ?? "Agency information unavailable") : "Responsible agency not yet verified.").font(.headline)
              Text(report.owner.reason).font(.subheadline)
              if report.owner.confidence != "high" { Text("Location or ownership may need review.").font(.caption).foregroundStyle(PatrolTheme.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          AgencyReportSection(report: report, plan: detail?.sendPlan) { await load() }
          Text("Status is provided by the backend. A closed report does not establish independent repair verification.").font(.caption).foregroundStyle(PatrolTheme.secondary)
        }
      }.padding()
    }.patrolScreen().navigationTitle("Report Details").navigationBarTitleDisplayMode(.inline)
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
  let beginScan: () -> Void
  @State private var pending: PendingObservation?
  var body: some View {
    List {
      if let observation = store.pending {
        Section("Saved on this phone · not uploaded") {
          Button { pending = observation } label: {
            HStack(spacing: 12) {
              Image(systemName: "tray.and.arrow.up").foregroundStyle(PatrolTheme.warning)
              VStack(alignment: .leading, spacing: 4) {
                Text("Pending upload").font(.subheadline.weight(.semibold)).foregroundStyle(PatrolTheme.text)
                Text("Review photo and location").font(.caption).foregroundStyle(PatrolTheme.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(PatrolTheme.secondary)
            }.padding(.vertical, 6)
          }
        }.listRowBackground(PatrolTheme.surface)
      }
      if !store.liveReports.isEmpty {
        Section("Saved from Live Scan and videos") {
          if let problem = store.liveError { ErrorNotice(text: problem) }
          if store.liveWaiting > 0 { Button("Send \(store.liveWaiting) now") { store.sendLiveReportsNow() } }
          ForEach(store.liveReports.reversed()) { report in
            NavigationLink { LiveReportDetailView(id: report.id) } label: { LiveReportRow(report: report) }
              .swipeActions { Button("Delete", role: .destructive) { store.deleteLiveReport(id: report.id) } }
          }
        }.listRowBackground(PatrolTheme.surface)
      }
      if store.loading { ProgressView("Refreshing your reports…") }
      if let error = store.error { ErrorNotice(text: error) }
      if store.missingReports > 0 { Text("\(store.missingReports) unavailable report IDs were removed from this phone.").font(.caption) }
      if !contributedReports.isEmpty {
      Section("Contributed from this phone") {
        ForEach(contributedReports) { report in
          NavigationLink { PotholeDetailView(id: report.id) } label: {
            HStack(spacing: 12) {
              if report.photoUrl != nil { PotholeThumbnail(url: report.photoUrl) }
              VStack(alignment: .leading, spacing: 6) {
                Text(report.title).font(.subheadline.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                  HStack { StatusBadge(status: report.status); reportDate(report) }
                  VStack(alignment: .leading, spacing: 4) { StatusBadge(status: report.status); reportDate(report) }
                }
              }
            }.padding(.vertical, 4)
          }
          .swipeActions { Button("Delete", role: .destructive) { store.removeFromMyReports(id: report.id) } }
        }
      }.listRowBackground(PatrolTheme.surface)
      }
    }
    .overlay {
      if store.myReports.isEmpty && store.liveReports.isEmpty && store.pending == nil && !store.loading && store.error == nil {
        PatrolEmptyState(title: "No reports yet.", symbol: "tray", actionTitle: "Start a Scan", action: beginScan).padding(16)
      }
    }
    .patrolScreen().navigationTitle("My Reports").navigationBarTitleDisplayMode(.inline).task(id: store.revision) { await store.refreshMyReports() }
    .refreshable { await store.refreshMyReports() }
    .sheet(item: $pending) { observation in NavigationStack { DetectionReviewView(observation: observation, location: location) }.environmentObject(store) }
  }
  /// Reports saved from Live Scan are listed in their own section, and lead to the same page.
  private var contributedReports: [Pothole] {
    store.myReports.filter { report in !store.liveReports.contains { $0.serverID == report.id } }
  }
  private func reportDate(_ report: Pothole) -> some View {
    Text(report.firstSeen.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(PatrolTheme.secondary)
  }
}

struct PatrolMapMarker: View {
  let status: PotholeStatus
  var body: some View {
    Image(systemName: "mappin.circle.fill").font(.system(size: 30))
      .foregroundStyle(status.color).background(PatrolTheme.background, in: Circle())
      .overlay(Circle().strokeBorder(PatrolTheme.text.opacity(0.6), lineWidth: 1))
      .frame(width: 44, height: 44).contentShape(Rectangle())
  }
}

struct PatrolMapButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.body.weight(.semibold)).frame(width: 44, height: 44)
      .foregroundStyle(enabled ? PatrolTheme.text : PatrolTheme.secondary)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .opacity(configuration.isPressed ? 0.65 : 1)
  }
}
