import Foundation
import Combine

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
  init() {
    baseURLString = UserDefaults.standard.string(forKey: "patrol.backendURL") ?? ""
    do {
      if let restored = try ObservationStorage.load() {
        if UserDefaults.standard.string(forKey: "patrol.completedCapture") == restored.id.uuidString { try ObservationStorage.remove() }
        else { pending = restored }
      }
    } catch { self.error = "Unable to restore the pending observation. Its file has been retained." }
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
    reports = []; myReports = []; health = "Not checked"; error = nil; revision = UUID()
  }
  func checkHealth() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    do { let result = try await api.health(); health = result.status == "ok" ? "Connected · HTTPS" : "Server status: \(result.status)" }
    catch { health = "Unavailable"; self.error = error.localizedDescription }
  }
  func refresh() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    do { reports = try await api.potholes(); error = nil }
    catch { self.error = error.localizedDescription }
  }
  private var idsKey: String { "patrol.reportIDs.\(baseURLString)" }
  private var savedIDs: [String] { UserDefaults.standard.stringArray(forKey: idsKey) ?? [] }
  func refreshMyReports() async {
    outstandingReads += 1; defer { outstandingReads -= 1 }
    var found: [Pothole] = []; var retained: [String] = []; missingReports = 0
    do {
      let client = try api
      for id in savedIDs {
        do { found.append(try await client.pothole(id: id).pothole); retained.append(id) }
        catch let failure as PatrolError where failure.status == 404 { missingReports += 1 }
        catch { throw error }
      }
      myReports = found; UserDefaults.standard.set(retained, forKey: idsKey); error = nil
    } catch { self.error = error.localizedDescription }
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
      var ids = savedIDs; if !ids.contains(result.potholeId) { ids.insert(result.potholeId, at: 0) }
      UserDefaults.standard.set(ids, forKey: idsKey)
      // Server success is authoritative. Never offer another upload solely because local cleanup failed.
      UserDefaults.standard.set(observation.id.uuidString, forKey: "patrol.completedCapture")
      pending = nil; uploadResult = result
      do { try ObservationStorage.remove() } catch { self.error = "Uploaded successfully, but local photo cleanup failed. Use Delete saved capture in Settings to remove the retained file." }
      reports.removeAll { $0.id == result.pothole.id }; reports.insert(result.pothole, at: 0); revision = UUID()
    } catch { self.error = error.localizedDescription }
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
