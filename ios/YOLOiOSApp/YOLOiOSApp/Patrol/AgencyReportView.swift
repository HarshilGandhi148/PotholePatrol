import SwiftUI
import UIKit
import WebKit

/// Reporting follows the backend's send plan. The app fills the agency's real page, and the resident
/// always taps the agency's own Submit. The app never submits for them.
@MainActor
struct AgencyReportSection: View {
  @EnvironmentObject private var store: PatrolStore
  @Environment(\.openURL) private var openURL
  let report: Pothole
  let plan: SendPlan?
  let onSent: () async -> Void
  @State private var showingForm = false
  @State private var error: String?

  var body: some View {
    GroupBox("Report to agency") {
      VStack(alignment: .leading, spacing: 10) {
        if report.sent {
          Label("Reported to \(plan?.agencyName ?? "the agency")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let plan {
          if let wait = plan.expectedResponse { Text("Typical response: \(wait)").font(.caption).foregroundStyle(.secondary) }
          switch plan.method {
          case "open_form":
            Text("Opens \(plan.agencyName ?? "the agency")'s own form. You check it and tap their Submit.").font(.subheadline)
            Button("Review and report") { showingForm = true }.buttonStyle(.borderedProminent)
          case "email":
            if let url = mailURL(plan) { Button("Open email") { openURL(url) }.buttonStyle(.borderedProminent) }
            submittedButton(plan)
          case "phone":
            if let script = plan.callScript { Text(script).font(.subheadline) }
            if let url = phoneURL(plan) { Button("Call \(plan.phone ?? "")") { openURL(url) }.buttonStyle(.borderedProminent) }
            submittedButton(plan)
          default:
            Text("\(plan.agencyName ?? "This owner") isn't connected yet. \(report.owner.reason)").font(.subheadline)
          }
        } else {
          Text(report.owner.reason).font(.subheadline)
        }
        if let error { ErrorNotice(text: error) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingForm) {
      if let plan {
        AgencyFormScreen(report: report, plan: plan) { await markSent(plan) }
      }
    }
  }

  private func submittedButton(_ plan: SendPlan) -> some View {
    Button("I submitted it") { Task { await markSent(plan) } }
  }
  private func markSent(_ plan: SendPlan) async {
    do { _ = try await store.api.markSent(id: report.id, method: plan.method); error = nil; await onSent() }
    catch { self.error = error.localizedDescription }
  }
  private func phoneURL(_ plan: SendPlan) -> URL? {
    plan.phone.flatMap { URL(string: "tel:" + $0.filter { $0.isNumber }) }
  }
  private func mailURL(_ plan: SendPlan) -> URL? {
    guard let email = plan.email, let to = email.to else { return nil }
    var parts = URLComponents(); parts.scheme = "mailto"; parts.path = to
    parts.queryItems = [URLQueryItem(name: "subject", value: email.subject), URLQueryItem(name: "body", value: email.body)]
    return parts.url
  }
}

@MainActor
private struct AgencyFormScreen: View {
  @Environment(\.dismiss) private var dismiss
  let report: Pothole
  let plan: SendPlan
  let onSubmitted: () async -> Void
  @StateObject private var form = AgencyFormController()
  @State private var copied: String?

  private var location: String? { plan.fields.first { $0.source == "location_search" }?.value }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          // Once the app has placed the location, the backend's step about pasting it no longer applies.
          ForEach((plan.instructions ?? []).filter { !form.locationPlaced || !$0.contains("Copy location") }, id: \.self) {
            Text($0).font(.caption)
          }
          HStack {
            if let location { Button("Copy location") { copy(location, as: "Location copied") } }
            Button("Copy report") { copy(plan.copyText, as: "Report copied") }
            if plan.autofillReady { Button("Fill this page") { form.fillNow() } }
          }.font(.subheadline).buttonStyle(.bordered)
          if let status = copied ?? form.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        if plan.url != nil {
          AgencyWebView(webView: form.webView)
        } else {
          Text("This agency has no form link.").frame(maxHeight: .infinity)
        }
      }
      .navigationTitle(plan.agencyName ?? "Report").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("I submitted it") { Task { await onSubmitted(); dismiss() } }
        }
      }
      .task { await form.start(plan: plan, photoURL: report.photoUrl, latitude: report.lat, longitude: report.lng) }
      .onDisappear { form.stop() }
    }
  }
  private func copy(_ text: String, as message: String) {
    UIPasteboard.general.string = text; copied = message
  }
}

private struct AgencyWebView: UIViewRepresentable {
  let webView: WKWebView
  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Agency pages change without a full page load, so this retries until each field has been filled.
@MainActor
private final class AgencyFormController: ObservableObject {
  @Published private(set) var status: String?
  @Published private(set) var locationPlaced = false
  let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  /// Where to put the map's pin, on forms with a map.
  private var coordinate: (latitude: Double, longitude: Double)?
  private var fields: [[String: String]] = []
  private var filled = Set<String>()
  private var photoBase64: String?
  private var timer: Timer?

  func start(plan: SendPlan, photoURL: URL?, latitude: Double, longitude: Double) async {
    guard let url = plan.url else { return }
    if webView.url == nil { webView.load(URLRequest(url: url)) }
    guard plan.autofillReady else { status = "Use Copy report, then paste it into the form."; return }
    if plan.fields.contains(where: { $0.source == "location_search" }) {
      coordinate = (latitude, longitude)
    }
    // The location goes on the map, not into a text field, and the photo is attached separately.
    fields = plan.fields.compactMap { field in
      guard field.source != "location_search", field.source != "photo_url", let value = field.value else { return nil }
      var entry = ["key": field.key, "value": value]
      if let selector = field.selector { entry["selector"] = selector }
      if let label = field.matchLabel { entry["label"] = label }
      return entry
    }
    if let photoURL, plan.fields.contains(where: { $0.source == "photo_url" }) {
      var request = URLRequest(url: photoURL)
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if let (data, _) = try? await URLSession.shared.data(for: request) { photoBase64 = data.base64EncodedString() }
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.fillNow() }
    }
  }

  func stop() { timer?.invalidate(); timer = nil }

  func fillNow() {
    placeLocation()
    let remaining = fields.filter { !filled.contains($0["key"] ?? "") }
    guard !remaining.isEmpty || photoBase64 != nil,
      let data = try? JSONSerialization.data(withJSONObject: remaining),
      let json = String(data: data, encoding: .utf8)
    else { return }
    let photo = photoBase64.map { "\"\($0)\"" } ?? "null"
    webView.evaluateJavaScript("(\(Self.fillScript))(\(json), \(photo))") { [weak self] result, _ in
      Task { @MainActor in self?.received(result) }
    }
  }

  /// Moves the form's map to the report's location, once, as soon as its map is ready.
  private func placeLocation() {
    guard let coordinate, !locationPlaced else { return }
    let call = "(\(Self.placeLocationScript))(\(coordinate.latitude), \(coordinate.longitude))"
    webView.evaluateJavaScript(call) { [weak self] result, _ in
      Task { @MainActor in
        guard let self, result as? Bool == true else { return }
        self.locationPlaced = true
        self.status = "Location set from this report. Check the pin, then tap Confirm Location. If it stays grey, tap the map at the pothole."
      }
    }
  }

  private func received(_ result: Any?) {
    guard let result = result as? [String: Any] else { return }
    (result["filled"] as? [String])?.forEach { filled.insert($0) }
    if result["photo"] as? Bool == true { photoBase64 = nil }
    if !fields.isEmpty {
      status = "Filled \(filled.count) of \(fields.count) fields. Check them before you submit."
    }
    if filled.count == fields.count && photoBase64 == nil { stop() }
  }

  /// Presses the map's Find my location button, answering it with the report's coordinates just for this press, so the
  /// map shows the report's location. Its button sits inside shadow DOM, which plain selectors can't reach. Returns
  /// whether the map was ready. Nothing here confirms the location or submits the form.
  private static let placeLocationScript = """
    function (latitude, longitude) {
      const find = (root, selector) => {
        for (const element of root.querySelectorAll('*')) {
          if (element.matches(selector)) return element;
          const found = element.shadowRoot && find(element.shadowRoot, selector);
          if (found) return found;
        }
        return null;
      };
      const host = find(document, '[aria-label="Find my location"]');
      if (!host || !find(document, 'canvas')) return false;
      const button = host.tagName === 'BUTTON' ? host : host.shadowRoot && host.shadowRoot.querySelector('button');
      if (!button) return false;
      const position = () => ({
        coords: { latitude, longitude, accuracy: 5, altitude: null, altitudeAccuracy: null, heading: null, speed: null },
        timestamp: Date.now()
      });
      const geolocation = {
        getCurrentPosition: (success) => setTimeout(() => success(position()), 0),
        watchPosition: (success) => { setTimeout(() => success(position()), 0); return 1; },
        clearWatch: () => {}
      };
      Object.defineProperty(navigator, 'geolocation', { get: () => geolocation, configurable: true });
      button.click();
      setTimeout(() => { delete navigator.geolocation; }, 5000);
      return true;
    }
    """

  /// Sets values the way a person typing would, so the page's own scripts see them. Never clicks anything.
  private static let fillScript = """
    function (fields, photo) {
      const setValue = (field, value) => {
        const proto = field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(field, value);
        field.dispatchEvent(new Event('input', { bubbles: true }));
        field.dispatchEvent(new Event('change', { bubbles: true }));
      };
      const usable = 'input:not([type=hidden]):not([type=file]):not([type=radio]):not([type=checkbox]), textarea';
      const byLabel = (text) => {
        const wanted = text.toLowerCase();
        for (const el of document.querySelectorAll('label, legend, span, div, p')) {
          if (el.children.length > 0 || !el.textContent.trim().toLowerCase().startsWith(wanted)) continue;
          if (el.htmlFor) { const linked = document.getElementById(el.htmlFor); if (linked) return linked; }
          let scope = el;
          for (let depth = 0; depth < 4 && scope; depth += 1, scope = scope.parentElement) {
            const found = scope.querySelector(usable);
            if (found) return found;
          }
        }
        return [...document.querySelectorAll(usable)].find((field) =>
          (field.getAttribute('aria-label') || field.placeholder || '').toLowerCase().startsWith(wanted)) || null;
      };
      const filled = [];
      for (const item of fields) {
        const field = (item.selector && document.querySelector(item.selector)) || (item.label && byLabel(item.label));
        if (!field) continue;
        if (field.value) { filled.push(item.key); continue; }
        setValue(field, item.value);
        filled.push(item.key);
      }
      let attached = false;
      const fileInput = document.querySelector('input[type=file]');
      if (photo && fileInput && !fileInput.files.length) {
        const bytes = Uint8Array.from(atob(photo), (c) => c.charCodeAt(0));
        const transfer = new DataTransfer();
        transfer.items.add(new File([bytes], 'pothole.jpg', { type: 'image/jpeg' }));
        fileInput.files = transfer.files;
        fileInput.dispatchEvent(new Event('change', { bubbles: true }));
        attached = fileInput.files.length > 0;
      }
      return { filled: filled, photo: attached };
    }
    """
}
