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
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.shield").font(.title).foregroundStyle(PatrolTheme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
              Text("Administrator Access").font(.title2.weight(.semibold))
              Text("Sign in to maintenance operations.").font(.subheadline).foregroundStyle(PatrolTheme.secondary)
            }
            PatrolCard {
              Text("Passcode").font(.subheadline.weight(.medium))
              SecureField("Administrator passcode", text: $passcode).textContentType(.password)
                .padding(12).background(PatrolTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                .submitLabel(.go).onSubmit { signIn() }
              Button(action: signIn) {
                HStack { if session.busy { ProgressView().tint(PatrolTheme.secondary) }; Text(session.busy ? "Verifying…" : "Sign In") }
              }.buttonStyle(PatrolPrimaryButton()).disabled(passcode.isEmpty || session.busy)
            }
            if let error = session.error { ErrorNotice(text: error) }
            Label("Verified by the server. Passcodes are never saved.", systemImage: "lock")
              .font(.caption).foregroundStyle(PatrolTheme.secondary)
          }.padding(20)
        }
        .patrolScreen().navigationTitle("Pothole Patrol").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { passcode = ""; dismiss() }.accessibilityLabel("Return to citizen app") } }
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private var assigned: [Pothole] { session.reports.filter { $0.owner.isPublic && (agency.isEmpty || $0.owner.agencyId == agency) } }
  private var unassigned: [Pothole] { session.reports.filter { !$0.owner.isPublic && $0.owner.kind != "private" && $0.status != .fixed } }
  private var mapReports: [Pothole] { session.reports.filter { $0.validCoordinate && (includeFixed || $0.status != .fixed) && (agency.isEmpty || $0.owner.agencyId == agency) } }
  var body: some View {
    List {
      Section {
        if !session.busy {
          if dynamicTypeSize.isAccessibilitySize { VStack(spacing: 8) { metrics } }
          else { HStack(spacing: 8) { metrics } }
        }
        if dynamicTypeSize.isAccessibilitySize {
          Picker("View", selection: $mode) { modes }.pickerStyle(.menu)
        } else {
          Picker("View", selection: $mode) { modes }.pickerStyle(.segmented)
        }
        Picker("Agency", selection: $agency) {
          Text("All agencies").tag(""); ForEach(session.agencies) { Text($0.name).tag($0.id) }
        }.disabled(session.busy)
      }.listRowBackground(PatrolTheme.background).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)).listRowSeparator(.hidden)
      if session.busy { ProgressView("Loading operations…").listRowBackground(PatrolTheme.surface) }
      if let error = session.error { ErrorNotice(text: error).listRowBackground(PatrolTheme.surface) }
      if mode == "active" {
        Section("Priority Queue · Backend Order") {
          if session.queue.isEmpty && !session.busy { Text("No assigned active potholes in this queue.").foregroundStyle(PatrolTheme.secondary) }
          ForEach(Array(session.queue.enumerated()), id: \.element.id) { rank, report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: true).environmentObject(session) } label: {
              HStack(alignment: .top, spacing: 12) {
                Text("\(rank + 1)").font(.caption.monospacedDigit()).foregroundStyle(PatrolTheme.secondary).frame(width: 20)
                if !dynamicTypeSize.isAccessibilitySize && report.photoUrl != nil { PotholeThumbnail(url: report.photoUrl) }
                VStack(alignment: .leading, spacing: 7) {
                  Text(report.title).font(.subheadline.weight(.semibold))
                  ViewThatFits(in: .horizontal) {
                    HStack { StatusBadge(status: report.status); Text("\(report.reportCount) reports").font(.caption).foregroundStyle(PatrolTheme.secondary) }
                    VStack(alignment: .leading, spacing: 4) { StatusBadge(status: report.status); Text("\(report.reportCount) reports").font(.caption) }
                  }
                  Text(report.owner.agencyName ?? "Unverified agency").font(.caption).foregroundStyle(PatrolTheme.secondary)
                }
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                  Text("\(report.priority.score)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(PatrolTheme.accent)
                  Text("Priority").font(.caption2).foregroundStyle(PatrolTheme.secondary)
                }.accessibilityElement(children: .combine)
              }.padding(.vertical, 5)
            }
          }
        }.listRowBackground(PatrolTheme.surface)
      } else if mode == "history" {
        Section("Fixed / History") {
          let history = assigned.filter { $0.status == .fixed }
          if history.isEmpty { Text("No fixed reports for this filter.").foregroundStyle(PatrolTheme.secondary) }
          ForEach(history) { report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: true).environmentObject(session) } label: { adminRow(report) }
          }
        }.listRowBackground(PatrolTheme.surface)
      } else if mode == "unassigned" {
        Section("Unassigned Observations") {
          Text("Read-only · ownership needs review. Shown across all agencies; excluded from the priority queue.").font(.caption).foregroundStyle(PatrolTheme.secondary)
          if unassigned.isEmpty { Text("No unassigned active observations.") }
          ForEach(unassigned) { report in
            NavigationLink { AdminPotholeDetailView(initial: report, canEdit: false).environmentObject(session) } label: { adminRow(report) }
          }
        }.listRowBackground(PatrolTheme.surface)
      } else {
        Section("Road network") {
          Toggle("Include fixed reports", isOn: $includeFixed)
          Button("Show All Reports") { if let fitted = PatrolMap.fitted(mapReports) { region = fitted } }
          Map(coordinateRegion: $region, annotationItems: mapReports) { report in
            MapAnnotation(coordinate: report.coordinate) {
              Button { selected = report } label: { PatrolMapMarker(status: report.status) }
                .accessibilityLabel(report.title)
            }
          }.frame(height: 360).listRowInsets(EdgeInsets())
        }.listRowBackground(PatrolTheme.surface)
      }
    }
    .patrolScreen().navigationTitle("Maintenance Operations").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      ToolbarItem(placement: .primaryAction) { Button("Log out") { session.logout() }.disabled(session.busy) }
    }
    .task(id: agency) { await session.refresh(agencyId: agency.isEmpty ? nil : agency) }
    .refreshable { await session.refresh(agencyId: agency.isEmpty ? nil : agency) }
    .sheet(item: $selected) { report in NavigationStack { AdminPotholeDetailView(initial: report, canEdit: report.owner.isPublic).environmentObject(session) } }
  }
  @ViewBuilder private var modes: some View {
    Text("Queue").tag("active"); Text("Map").tag("map"); Text("History").tag("history"); Text("Unassigned").tag("unassigned")
  }
  @ViewBuilder private var metrics: some View {
    PatrolMetricCard(title: "Active", value: assigned.filter { $0.status != .fixed }.count)
    PatrolMetricCard(title: "Unassigned", value: unassigned.count)
    PatrolMetricCard(title: "Fixed", value: assigned.filter { $0.status == .fixed }.count)
  }
  private func adminRow(_ report: Pothole) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(report.title).font(.subheadline.weight(.semibold)); StatusBadge(status: report.status)
      Text("\(report.reportCount) reporters · Updated \(report.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(PatrolTheme.secondary)
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
          Text(report.owner.reason).font(.subheadline).foregroundStyle(PatrolTheme.secondary)
          Text("\(report.reportCount) distinct reporters · Updated \(report.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
          if canEdit {
            GroupBox("Backend priority") {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(report.priority.score) total").font(.title2.bold()).foregroundStyle(PatrolTheme.accent)
                LabeledContent("Reporters × 10", value: "\(report.priority.reporters) × 10")
                LabeledContent("Road classification", value: "\(report.priority.roadClassPoints)")
                LabeledContent("Days open", value: "\(report.priority.daysOpenPoints)")
              }.font(.subheadline)
            }
            GroupBox("Update public status") {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(PotholeStatus.allCases) { status in
                  Button {
                    if status == .fixed { confirmFixed = true } else { Task { await change(status) } }
                  } label: {
                    Text("Mark \(status.title)").frame(maxWidth: .infinity, minHeight: 44)
                      .background(PatrolTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                  }
                    .disabled(session.busy || report.status == status)
                }
                Text("Only a successful server response changes the public status. Fixed does not imply independent repair verification.").font(.caption).foregroundStyle(PatrolTheme.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          } else { Text("Read-only · not assigned or ranked. Jurisdiction review is required.").font(.subheadline).foregroundStyle(PatrolTheme.secondary) }
          if session.busy { ProgressView("Updating…") }
          if let error = session.error { ErrorNotice(text: error) }
        }
      }.padding()
    }
    .patrolScreen().navigationTitle("Operations Detail").navigationBarTitleDisplayMode(.inline)
    .alert("Mark this pothole as fixed?", isPresented: $confirmFixed) {
      Button("Cancel", role: .cancel) {}
      Button("Mark Fixed") { Task { await change(.fixed) } }
    } message: { Text("The updated status will be visible to residents.") }
  }
  private func change(_ status: PotholeStatus) async {
    if let updated = await session.update(id: report.id, status: status) { report = updated; await store.refresh() }
  }
}
