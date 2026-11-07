import MapKit
import SwiftUI

extension LiveReport {
  fileprivate var areaText: String? {
    areaSquareMeters.map { String(format: "≈%.1f ft²", $0 * 10.7639) }
  }
  fileprivate var image: UIImage? { UIImage(data: jpeg) }
  fileprivate var statusText: String {
    if serverID != nil { return "Sent to Pothole Patrol" }
    if rejection != nil { return "Rejected by the backend" }
    return "Saved on this phone · waiting to send"
  }
}

/// A saved Live Scan report in the My Reports list.
@MainActor
struct LiveReportRow: View {
  let report: LiveReport
  var body: some View {
    HStack(spacing: 12) {
      if let image = report.image {
        Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48)
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(report.title ?? "Pothole from Live Scan").font(.subheadline.weight(.semibold))
        Text(report.statusText).font(.caption).foregroundStyle(report.rejection == nil ? PatrolTheme.secondary : PatrolTheme.error)
        Text(report.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(PatrolTheme.secondary)
      }
    }.padding(.vertical, 4)
  }
}

/// Everything saved about one Live Scan report. Once it's on the backend, this leads to reporting it to an agency.
@MainActor
struct LiveReportDetailView: View {
  @EnvironmentObject private var store: PatrolStore
  @Environment(\.dismiss) private var dismiss
  let id: UUID
  @State private var confirmDelete = false

  var body: some View {
    ScrollView {
      if let report = store.liveReports.first(where: { $0.id == id }) { content(report).padding() }
    }
    .patrolScreen().navigationTitle("Live Scan report").navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Delete this report and its photo from this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        store.deleteLiveReport(id: id)
        dismiss()
      }
    } message: {
      Text("If it was already sent, it stays on the backend.")
    }
  }

  private func content(_ report: LiveReport) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if let image = report.image {
        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
      }
      Text(report.title ?? "Pothole from Live Scan").font(.title3.bold())
      Text(report.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(PatrolTheme.secondary)
      GroupBox("Estimated size") {
        VStack(alignment: .leading, spacing: 6) {
          if let area = report.areaText { Text("Area \(area)").font(.headline) }
          LabeledContent("Width", value: String(format: "%.0f in", report.widthMeters * 39.3701))
          if let length = report.lengthMeters {
            LabeledContent("Length", value: String(format: "%.0f in", length * 39.3701))
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("Estimated location") {
        VStack(alignment: .leading, spacing: 8) {
          Text(String(format: "%.5f, %.5f", report.lat, report.lng)).font(.subheadline).textSelection(.enabled)
          Map(
            coordinateRegion: .constant(
              MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: report.lat, longitude: report.lng),
                span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002))),
            annotationItems: [report]
          ) { item in
            MapMarker(coordinate: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng))
          }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      status(report)
      Button("Delete report", role: .destructive) { confirmDelete = true }
    }
  }

  @ViewBuilder private func status(_ report: LiveReport) -> some View {
    GroupBox(report.statusText) {
      VStack(alignment: .leading, spacing: 10) {
        if let serverID = report.serverID {
          if report.sentTo == store.baseURLString {
            NavigationLink("Open report and send to agency") { PotholeDetailView(id: serverID) }
              .buttonStyle(PatrolPrimaryButton())
          } else {
            Text("This was sent to a different backend address.").font(.subheadline)
          }
        } else {
          if let problem = report.rejection ?? store.liveError { ErrorNotice(text: problem) }
          Button("Send now") { store.sendLiveReportsNow() }.buttonStyle(PatrolPrimaryButton())
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
