import SwiftUI
import MapKit

@MainActor
struct AdminEntryView: View {
  @StateObject private var session: AdminSession
  @State private var passcode = ""
  @Environment(\.dismiss) private var dismiss
  init(api: PotholeAPI) { _session = StateObject(wrappedValue: AdminSession(api: api)) }
  var body: some View {
    NavigationStack {
      if session.authenticated { AdminDashboardView().environmentObject(session) }
      else {
        Form {
          Section {
            Label("Administrator Sign In", systemImage: "lock.shield.fill").font(.title3.bold())
            Text("Maintenance operations require verification by the Pothole Patrol server.").font(.subheadline).foregroundStyle(.secondary)
            SecureField("Administrator passcode", text: $passcode).textContentType(.password).submitLabel(.go).onSubmit { signIn() }
            Button(action: signIn) { if session.busy { ProgressView() }; Text("Sign In") }.disabled(passcode.isEmpty || session.busy)
          }
          if let error = session.error { Section { ErrorNotice(text: error) } }
          Section { Text("Passcodes are never saved. A verified session token is held in the iOS Keychain and rechecked with the server before reopening operations.").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Pothole Patrol")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Return to citizen app") { passcode = ""; dismiss() } } }
      }
    }.task { await session.restore() }.onDisappear { passcode = "" }
  }
  private func signIn() {
    guard !passcode.isEmpty, !session.busy else { return }
    let entered = passcode; passcode = ""
    Task { await session.login(passcode: entered) }
  }
}

@MainActor
struct AdminDashboardView: View {
  @EnvironmentObject private var session: AdminSession
  @Environment(\.dismiss) private var dismiss
  @State private var mode = "active"
  @State private var agency = ""
  @State private var region = PatrolMap.home
  @State private var selected: Pothole?
  @State private var includeFixed = false
  private var assigned: [Pothole] { session.reports.filter { $0.owner.isPublic && (agency.isEmpty || $0.owner.agencyId == agency) } }
  private var unassigned: [Pothole] { session.reports.filter { !$0.owner.isPublic && $0.owner.kind != "private" && $0.status != .fixed } }
  private var mapReports: [Pothole] { session.reports.filter { $0.validCoordinate && (includeFixed || $0.status != .fixed) && (agency.isEmpty || $0.owner.agencyId == agency) } }
  var body: some View {
    List {
      Section {
        HStack {
          VStack(alignment: .leading) { Text("Active assigned").font(.caption).foregroundStyle(.secondary); Text("\(assigned.filter { $0.status != .fixed }.count)").font(.title2.bold()) }
          Spacer()
          VStack(alignment: .leading) { Text("Needs jurisdiction review").font(.caption).foregroundStyle(.secondary); Text("\(unassigned.count)").font(.title2.bold()) }
        }
        Picker("View", selection: $mode) {
          Text("Active").tag("active"); Text("History").tag("history"); Text("Unassigned").tag("unassigned"); Text("Map").tag("map")
        }.pickerStyle(.segmented)
        Picker("Agency", selection: $agency) {
          Text("All agencies").tag(""); ForEach(session.agencies) { Text($0.name).tag($0.id) }
        }.disabled(session.busy)
      }
      if session.busy { ProgressView("Loading operations…") }
      if let error = session.error { ErrorNotice(text: error) }
      if mode == "active" {
        Section("Authenticated ranked queue · backend order") {
          if session.queue.isEmpty && !session.busy { Text("No assigned active potholes in this queue.").foregroundStyle(.secondary) }
          ForEach(Array(session.queue.enumerated()), id: \.element.id) { rank, report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: true).environmentObject(session) } label: {
              HStack(alignment: .top, spacing: 12) {
                Text("\(rank + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                PotholeThumbnail(url: report.photoUrl)
                VStack(alignment: .leading, spacing: 7) {
                  Text(report.title).font(.subheadline.weight(.semibold))
                  HStack { StatusBadge(status: report.status); Text("\(report.reportCount) reporters").font(.caption) }
                  Text(report.owner.agencyName ?? "Unverified agency").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(report.priority.score)").font(.title3.bold().monospacedDigit()).foregroundStyle(.blue)
              }.padding(.vertical, 5)
            }
          }
        }
      } else if mode == "history" {
        Section("Fixed / History") {
          let history = assigned.filter { $0.status == .fixed }
          if history.isEmpty { Text("No fixed reports for this filter.").foregroundStyle(.secondary) }
          ForEach(history) { report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: true).environmentObject(session) } label: { adminRow(report) }
          }
        }
      } else if mode == "unassigned" {
        Section("Unassigned / Needs Jurisdiction Review") {
          Text("Read-only public observations. These are excluded from the authenticated ranked queue. Indianapolis/Fishers ownership coverage is not assumed. Agency filtering does not hide this section.").font(.caption).foregroundStyle(.secondary)
          if unassigned.isEmpty { Text("No unassigned active observations.") }
          ForEach(unassigned) { report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: false).environmentObject(session) } label: { adminRow(report) }
          }
        }
      } else {
        Section("Road network") {
          Toggle("Include fixed reports", isOn: $includeFixed)
          Button("Show All Reports") { if let fitted = PatrolMap.fitted(mapReports) { region = fitted } }
          Map(coordinateRegion: $region, annotationItems: mapReports) { report in
            MapAnnotation(coordinate: report.coordinate) {
              Button { selected = report } label: { Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(report.status.color).background(.white, in: Circle()) }
                .accessibilityLabel(report.title)
            }
          }.frame(height: 360).listRowInsets(EdgeInsets())
        }
      }
    }
    .navigationTitle("Maintenance Operations").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      ToolbarItem(placement: .primaryAction) { Button("Log out") { session.logout() }.disabled(session.busy) }
    }
    .task(id: agency) { await session.refresh(agencyId: agency.isEmpty ? nil : agency) }
    .refreshable { await session.refresh(agencyId: agency.isEmpty ? nil : agency) }
    .sheet(item: $selected) { report in NavigationStack { AdminPotholeDetailView(initial: report, canEdit: report.owner.isPublic).environmentObject(session) } }
  }
  private func adminRow(_ report: Pothole) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(report.title).font(.subheadline.weight(.semibold)); StatusBadge(status: report.status)
      Text("\(report.reportCount) reporters · Updated \(report.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 5)
  }
}

@MainActor
struct AdminPotholeDetailView: View {
  @EnvironmentObject private var session: AdminSession
  @EnvironmentObject private var store: PatrolStore
  @State private var report: Pothole
  @State private var confirmFixed = false
  let canEdit: Bool
  init(initial: Pothole, canEdit: Bool) { _report = State(initialValue: initial); self.canEdit = canEdit }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if session.authenticated {
          PotholePhoto(url: report.photoUrl)
          Text(report.title).font(.title3.bold()); StatusBadge(status: report.status)
          Text(report.owner.agencyName ?? "Responsible agency not yet verified.").font(.headline)
          Text(report.owner.reason).font(.subheadline).foregroundStyle(.secondary)
          Text("\(report.reportCount) distinct reporters · Updated \(report.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
          if canEdit {
            GroupBox("Backend priority") {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(report.priority.score) total").font(.title2.bold())
                LabeledContent("Reporters × 10", value: "\(report.priority.reporters) × 10")
                LabeledContent("Road classification", value: "\(report.priority.roadClassPoints)")
                LabeledContent("Days open", value: "\(report.priority.daysOpenPoints)")
              }.font(.subheadline)
            }
            GroupBox("Update public status") {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(PotholeStatus.allCases) { status in
                  Button("Mark \(status.title)") {
                    if status == .fixed { confirmFixed = true } else { Task { await change(status) } }
                  }.buttonStyle(.bordered).disabled(session.busy || report.status == status)
                }
                Text("Only a successful server response changes the public status. Fixed does not imply independent repair verification.").font(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          } else { Text("Read-only · not assigned or ranked. Jurisdiction review is required.").font(.subheadline).foregroundStyle(.secondary) }
          if session.busy { ProgressView("Updating…") }
          if let error = session.error { ErrorNotice(text: error) }
        }
      }.padding()
    }
    .navigationTitle("Operations detail").navigationBarTitleDisplayMode(.inline)
    .alert("Mark this pothole as fixed?", isPresented: $confirmFixed) {
      Button("Cancel", role: .cancel) {}
      Button("Mark Fixed", role: .destructive) { Task { await change(.fixed) } }
    } message: { Text("The updated status will be visible to residents.") }
  }
  private func change(_ status: PotholeStatus) async {
    if let updated = await session.update(id: report.id, status: status) { report = updated; await store.refresh() }
  }
}
