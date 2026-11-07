import Foundation
import Combine
import UIKit

/// A pothole saved from Live Scan. It stays on the phone, and records whether it has reached the backend.
struct LiveReport: Codable, Identifiable {
  var id = UUID()
  var serverID: String?
  var title: String?
  /// The backend address this was sent to.
  var sentTo: String?
  /// Why the backend refused this report, in which case it isn't retried automatically.
  var rejection: String?
  let jpeg: Data
  let lat: Double
  let lng: Double
  let capturedAt: Date
  let widthMeters: Double
  let lengthMeters: Double?
  let areaSquareMeters: Double?

  /// The current server ignores these. They're ready for when it has somewhere to store size.
  var sizeFields: [String: String] {
    var fields = ["width_m": String(format: "%.2f", widthMeters)]
    if let lengthMeters { fields["length_m"] = String(format: "%.2f", lengthMeters) }
    if let areaSquareMeters { fields["area_m2"] = String(format: "%.3f", areaSquareMeters) }
    return fields
  }
}

/// Keeps saved Live Scan reports through a quit, one protected file each, until the person deletes them.
enum LiveReportStorage {
  private static func directory() throws -> URL {
    var dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("PotholePatrol/live-reports", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
    return dir
  }
  private static func file(for id: UUID) throws -> URL {
    try directory().appendingPathComponent("\(id.uuidString).json")
  }
  static func loadAll() -> [LiveReport] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap { file in
      (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LiveReport.self, from: $0) }
    }.sorted { $0.capturedAt < $1.capturedAt }
  }
  static func save(_ report: LiveReport) throws {
    try JSONEncoder().encode(report).write(to: file(for: report.id), options: [.atomic, .completeFileProtection])
  }
  static func remove(_ id: UUID) {
    if let file = try? file(for: id) { try? FileManager.default.removeItem(at: file) }
  }
}

@MainActor
final class PatrolStore: ObservableObject {
  @Published private(set) var baseURLString: String
  @Published private(set) var reports: [Pothole] = []
  @Published private(set) var myReports: [Pothole] = []
  @Published private(set) var pending: PendingObservation?
  @Published private var outstandingReads = 0
  var loading: Bool { outstandingReads > 0 }
  @Published var error: String?
  @Published private(set) var uploadResult: DetectionResponse?
  @Published private(set) var uploading = false
  @Published private(set) var health = "Not checked"
  @Published private(set) var missingReports = 0
  @Published private(set) var revision = UUID()
  /// Saved Live Scan reports, oldest first.
  @Published private(set) var liveReports: [LiveReport] = []
  @Published private var liveEncoding = 0
  @Published private var liveSent = 0
  /// Why Live Scan's reports aren't going through, if they aren't.
  @Published private(set) var liveError: String?
  private var liveSending = false
  private var nextReportToSend: LiveReport? {
    liveReports.first { $0.serverID == nil && $0.rejection == nil }
  }
  /// How many Live Scan reports haven't reached the backend yet.
  var liveWaiting: Int { liveReports.filter { $0.serverID == nil && $0.rejection == nil }.count + liveEncoding }
  /// A short summary of what's being sent, or `nil` if nothing is happening.
  var liveStatus: String? {
    if let liveError { return liveError }
    if liveWaiting > 0 { return "Sent \(liveSent) · sending \(liveWaiting)" }
    return liveSent > 0 ? "Sent \(liveSent)" : nil
  }
  init() {
    baseURLString = UserDefaults.standard.string(forKey: "patrol.backendURL") ?? ""
    do {
      if let restored = try ObservationStorage.load() {
        if UserDefaults.standard.string(forKey: "patrol.completedCapture") == restored.id.uuidString { try ObservationStorage.remove() }
        else { pending = restored }
      }
    } catch { self.error = "Unable to restore the pending observation. Its file has been retained." }
    myReports = savedReports()
    liveReports = LiveReportStorage.loadAll()
    resumeLiveReports()
  }
  /// Tries again to send any reports that are still waiting.
  func resumeLiveReports() {
    guard nextReportToSend != nil else { return }
    Task { await sendLiveReports() }
  }
  /// Tries every unsent report right away, including any the backend rejected before.
  func sendLiveReportsNow() {
    for report in liveReports where report.rejection != nil { update(report.id) { $0.rejection = nil } }
    liveError = nil
    resumeLiveReports()
  }
  /// Deletes a Live Scan report and its photo from this phone. If it was sent, it stays on the backend.
  func deleteLiveReport(id: UUID) {
    let serverID = liveReports.first { $0.id == id }?.serverID
    LiveReportStorage.remove(id)
    liveReports.removeAll { $0.id == id }
    if nextReportToSend == nil { liveError = nil }
    // Several saved reports can share one backend pothole, because it merges nearby reports.
    if let serverID, !liveReports.contains(where: { $0.serverID == serverID }) { removeFromMyReports(id: serverID) }
  }
  /// Takes a report off this phone's list. It stays on the backend.
  func removeFromMyReports(id: String) {
    UserDefaults.standard.set(savedIDs.filter { $0 != id }, forKey: idsKey)
    myReports.removeAll { $0.id == id }
    saveReports()
  }
  private func update(_ id: UUID, _ change: (inout LiveReport) -> Void) {
    guard let index = liveReports.firstIndex(where: { $0.id == id }) else { return }
    change(&liveReports[index])
    try? LiveReportStorage.save(liveReports[index])
  }
  var api: PotholeAPI {
    get throws { PotholeAPI(baseURL: try PotholeAPI.validatedURL(baseURLString)) }
  }
  var configured: Bool { (try? PotholeAPI.validatedURL(baseURLString)) != nil }
  func configure(_ text: String) throws {
    guard !uploading, !loading else { throw PatrolError.message("Wait for current requests before changing servers.") }
    let url = try PotholeAPI.validatedURL(text)
    CredentialStore.remove(server: baseURLString)
    baseURLString = url.absoluteString
    UserDefaults.standard.set(baseURLString, forKey: "patrol.backendURL")
    reports = []; myReports = savedReports(); health = "Not checked"; error = nil; revision = UUID()
    resumeLiveReports()
  }
  func checkHealth() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    do { let result = try await api.health(); health = result.status == "ok" ? "Connected · HTTPS" : "Server status: \(result.status)" }
    catch { health = "Unavailable"; self.error = error.localizedDescription }
  }
  func refresh() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    do { reports = try await api.potholes(); error = nil }
    catch { show(error) }
  }
  /// A newer refresh cancels the one before it, which isn't a problem worth showing.
  private func show(_ failure: Error) {
    if (failure as? URLError)?.code == .cancelled || failure is CancellationError { return }
    error = failure.localizedDescription
  }
  private var idsKey: String { "patrol.reportIDs.\(baseURLString)" }
  private var savedIDs: [String] { UserDefaults.standard.stringArray(forKey: idsKey) ?? [] }
  /// A copy of My Reports for this server, so the list survives a quit and shows without a connection.
  private var reportsKey: String { "patrol.myReports.\(baseURLString)" }
  private func savedReports() -> [Pothole] {
    UserDefaults.standard.data(forKey: reportsKey).flatMap { try? JSONDecoder().decode([Pothole].self, from: $0) } ?? []
  }
  private func saveReports() {
    if let data = try? JSONEncoder().encode(myReports) { UserDefaults.standard.set(data, forKey: reportsKey) }
  }
  /// Updates My Reports from the server. A report can be accepted while this waits on the network, so this reads the
  /// saved IDs as it goes, and only removes an ID the server says no longer exists.
  func refreshMyReports() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    let client: PotholeAPI
    do { client = try api } catch { show(error); return }
    var latest: [String: Pothole] = [:]; var gone = Set<String>(); var checked = Set<String>(); var failure: Error?
    while let id = savedIDs.first(where: { !checked.contains($0) }) {
      checked.insert(id)
      do { latest[id] = try await client.pothole(id: id).pothole }
      catch let notFound as PatrolError where notFound.status == 404 { gone.insert(id) }
      catch {
        if Task.isCancelled { return }
        failure = error
      }
    }
    UserDefaults.standard.set(savedIDs.filter { !gone.contains($0) }, forKey: idsKey)
    missingReports = gone.count
    // Reports that couldn't be checked keep their last known details.
    let known = Dictionary(myReports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    myReports = savedIDs.compactMap { latest[$0] ?? known[$0] }
    saveReports()
    if let failure { show(failure) } else { error = nil }
  }
  func retain(_ observation: PendingObservation) throws {
    var observation = observation
    if let existing = pending, existing.id != observation.id { throw PatrolError.message("Review or discard the existing pending photo first.") }
    if let existing = pending, existing.id == observation.id, let server = existing.backendURL { observation.backendURL = server }
    try ObservationStorage.save(observation); pending = observation; uploadResult = nil; error = nil
  }
  func discardPending() throws { guard !uploading else { throw PatrolError.message("Wait for the upload to finish.") }; try ObservationStorage.remove(); pending = nil; uploadResult = nil }
  func upload() async {
    guard !uploading, var observation = pending, observation.locationConfirmed,
      let lat = observation.lat, let lng = observation.lng else { error = "Confirm the photo and its location before uploading."; return }
    uploading = true; defer { uploading = false }
    do {
      let client = try api
      if let origin = observation.backendURL, origin != client.baseURL.absoluteString {
        throw PatrolError.message("This observation belongs to another backend. Restore that URL to retry the original upload.")
      }
      observation.backendURL = client.baseURL.absoluteString; try retain(observation)
      let result = try await client.postDetection(jpeg: observation.jpeg, lat: lat, lng: lng,
        capturedAt: observation.capturedAt, deviceId: DeviceIdentity.current)
      // Server success is authoritative. Never offer another upload solely because local cleanup failed.
      UserDefaults.standard.set(observation.id.uuidString, forKey: "patrol.completedCapture")
      pending = nil; uploadResult = result
      do { try ObservationStorage.remove() } catch { self.error = "Uploaded successfully, but local photo cleanup failed. Use Delete saved capture in Settings to remove the retained file." }
      remember(result)
    } catch { self.error = error.localizedDescription }
  }
  private func remember(_ result: DetectionResponse) {
    var ids = savedIDs; if !ids.contains(result.potholeId) { ids.insert(result.potholeId, at: 0) }
    UserDefaults.standard.set(ids, forKey: idsKey)
    reports.removeAll { $0.id == result.pothole.id }; reports.insert(result.pothole, at: 0)
    myReports.removeAll { $0.id == result.pothole.id }; myReports.insert(result.pothole, at: 0)
    saveReports()
    revision = UUID()
  }

  /// Saves a pothole from Live Scan as a report on this phone, then sends it to the backend.
  func reportLive(
    photo: UIImage, coordinate: (lat: Double, lng: Double), capturedAt: Date, width: Double,
    length: Double?, area: Double?
  ) {
    liveEncoding += 1
    Task {
      let jpeg = await Task.detached { try? ObservationStorage.jpeg(from: photo) }.value
      liveEncoding -= 1
      guard let jpeg else { liveError = "A photo couldn't be prepared."; return }
      let report = LiveReport(
        jpeg: jpeg, lat: coordinate.lat, lng: coordinate.lng, capturedAt: capturedAt,
        widthMeters: width, lengthMeters: length, areaSquareMeters: area)
      do { try LiveReportStorage.save(report) } catch {
        liveError = "A report couldn't be saved on this phone, so it will be lost if the app quits."
      }
      liveReports.append(report)
      await sendLiveReports()
    }
  }

  private static let maximumLiveAttempts = 10

  /// Sends queued reports in order, retrying through a poor connection. Retries are safe, because the server counts
  /// the same device on the same pothole once.
  private func sendLiveReports() async {
    guard !liveSending else { return }
    liveSending = true; defer { liveSending = false }
    var attempts = 0
    while let report = nextReportToSend {
      guard configured else { liveError = "Not sending. Set the backend URL under More."; return }
      do {
        let result = try await api.postDetection(
          jpeg: report.jpeg, lat: report.lat, lng: report.lng, capturedAt: report.capturedAt,
          deviceId: DeviceIdentity.current, extraFields: report.sizeFields)
        let sentTo = baseURLString
        update(report.id) {
          $0.serverID = result.potholeId; $0.title = result.pothole.title; $0.sentTo = sentTo
        }
        liveSent += 1; liveError = nil; attempts = 0
        // It may have been deleted while it was being sent.
        if liveReports.contains(where: { $0.id == report.id }) { remember(result) }
      } catch {
        attempts += 1
        // Only these mean the server rejected this report itself, so sending it again wouldn't help. Anything else
        // may be a problem with the connection, like ngrok answering 404 while its tunnel is offline.
        let status = (error as? PatrolError)?.status ?? 0
        if [400, 413, 415, 422].contains(status) {
          update(report.id) { $0.rejection = error.localizedDescription }
          attempts = 0
          liveError = "The backend rejected a report: \(error.localizedDescription)"
        } else if attempts >= Self.maximumLiveAttempts {
          // Reports stay saved, and are tried again when the app next opens.
          liveError = "Can't send yet: \(error.localizedDescription) \(liveWaiting) saved on this phone."
          return
        } else {
          liveError = "Can't send yet: \(error.localizedDescription) Retrying…"
          try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
      }
    }
  }
}

/// Admin state is separate from citizen state. Authentication is established only by a server response.
@MainActor
final class AdminSession: ObservableObject {
  @Published private(set) var authenticated = false
  @Published private(set) var queue: [Pothole] = []
  @Published private(set) var reports: [Pothole] = []
  @Published private(set) var agencies: [Agency] = []
  @Published private(set) var busy = false
  @Published var error: String?
  private let api: PotholeAPI
  private var token: String?
  private var agencyFilter: String?
  init(api: PotholeAPI) { self.api = api }
  func login(passcode: String) async {
    guard !busy else { return }; busy = true; defer { busy = false }
    do {
      let verified = try await api.verifyOfficial(passcode: passcode)
      let ranked = try await api.queue(token: verified.token)
      try CredentialStore.save(verified.token, server: api.baseURL.absoluteString)
      token = verified.token; queue = ranked.filter { $0.status != .fixed }; authenticated = true; error = nil
    } catch { handle(error, signingIn: true) }
  }
  func restore() async {
    guard !busy, !authenticated, let saved = CredentialStore.read(server: api.baseURL.absoluteString) else { return }
    busy = true; defer { busy = false }
    do {
      let ranked = try await api.queue(token: saved)
      token = saved; queue = ranked.filter { $0.status != .fixed }; authenticated = true; error = nil
    } catch { handle(error) }
  }
  func logout() {
    CredentialStore.remove(server: api.baseURL.absoluteString)
    token = nil; authenticated = false; queue = []; reports = []; agencies = []
  }
  func refresh(agencyId: String? = nil) async {
    guard let token, authenticated, !busy else { return }; busy = true; defer { busy = false }
    agencyFilter = agencyId
    do {
      queue = try await api.queue(token: token, agencyId: agencyId).filter { $0.status != .fixed }
      reports = try await api.potholes(); agencies = try await api.agencies(); error = nil
    } catch { handle(error) }
  }
  func update(id: String, status: PotholeStatus) async -> Pothole? {
    guard let token, authenticated, !busy else { return nil }; busy = true; defer { busy = false }
    do {
      let updated = try await api.setStatus(id: id, status: status, token: token)
      reports = reports.map { $0.id == id ? updated : $0 }
      queue.removeAll { $0.id == id }; error = nil
      // Re-fetch the authoritative rank rather than recomputing a client-side score.
      do { queue = try await api.queue(token: token, agencyId: agencyFilter).filter { $0.status != .fixed } }
      catch { handle(error) }
      return updated
    } catch { handle(error); return nil }
  }
  private func handle(_ failure: Error, signingIn: Bool = false) {
    if let failure = failure as? PatrolError, failure.status == 401 {
      logout(); error = signingIn ? "Wrong passcode." : "Your official session is no longer valid. Sign in again."
    } else { error = failure.localizedDescription }
  }
}
