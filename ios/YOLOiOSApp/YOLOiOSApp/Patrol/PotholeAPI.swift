import Foundation

/// The documented backend contract. Public calls never carry an administrator credential.
final class PotholeAPI {
  let baseURL: URL
  private static let transport = URLSession(configuration: .ephemeral, delegate: APIRedirectGuard(), delegateQueue: nil)
  private let session: URLSession
  init(baseURL: URL, session: URLSession? = nil) { self.baseURL = baseURL; self.session = session ?? Self.transport }

  static func validatedURL(_ text: String) throws -> URL {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.url != nil
    else { throw PatrolError.message("Enter an HTTPS base URL without credentials, query, or fragment.") }
    var normalized = parts
    while normalized.percentEncodedPath.hasSuffix("/") { normalized.percentEncodedPath.removeLast() }
    return normalized.url!
  }

  func health() async throws -> HealthResponse { try await send(request("health")) }
  func potholes(agencyId: String? = nil, status: PotholeStatus? = nil) async throws -> [Pothole] {
    var query = [URLQueryItem(name: "limit", value: "1000")]
    if let agencyId { query.append(URLQueryItem(name: "agency_id", value: agencyId)) }
    if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
    let response: PotholeList = try await send(request("potholes", query: query))
    return response.potholes
  }
  func pothole(id: String) async throws -> PotholeDetail {
    try await send(request("potholes/\(try pathID(id))"))
  }
  func agencies() async throws -> [Agency] {
    let response: AgencyList = try await send(request("agencies")); return response.agencies
  }
  func markSent(id: String, method: String) async throws -> SendResponse {
    guard ["open_form", "email", "phone"].contains(method) else {
      throw PatrolError.message("This reporting method cannot be marked as submitted.")
    }
    return try await send(request("potholes/\(try pathID(id))/send", method: "POST", json: ["method": method]))
  }
  func verifyOfficial(passcode: String) async throws -> VerifyResponse {
    let response: VerifyResponse = try await send(request("officials/verify", method: "POST", json: ["passcode": passcode]))
    guard response.verified, !response.token.isEmpty else { throw PatrolError.message("The server did not verify this sign-in.") }
    return response
  }
  func queue(token: String, agencyId: String? = nil) async throws -> [Pothole] {
    let query = agencyId.map { [URLQueryItem(name: "agency_id", value: $0)] } ?? []
    let response: PotholeList = try await send(request("queue", query: query, token: token))
    return response.potholes
  }
  func setStatus(id: String, status: PotholeStatus, token: String) async throws -> Pothole {
    let response: PotholeWrapper = try await send(request("potholes/\(try pathID(id))/status", method: "PATCH", json: ["status": status.rawValue], token: token))
    return response.pothole
  }
  /// Downloads a pothole photo. SwiftUI's `AsyncImage` can't set the header that gets past ngrok's warning page.
  static func photoData(at url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      http.mimeType?.hasPrefix("image/") == true
    else { throw PatrolError.message("The photo couldn't be loaded.") }
    return data
  }
  /// `extraFields` are sent alongside the required fields. The server ignores any it doesn't know.
  func postDetection(
    jpeg: Data, lat: Double, lng: Double, capturedAt: Date, deviceId: String,
    extraFields: [String: String] = [:]
  ) async throws -> DetectionResponse {
    guard !jpeg.isEmpty, jpeg.count <= 10 * 1024 * 1024, lat.isFinite, lng.isFinite,
      (-90...90).contains(lat), (-180...180).contains(lng) else {
      throw PatrolError.message("A JPEG under 10 MB and confirmed coordinates are required.")
    }
    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()
    let fields = ["lat": String(lat), "lng": String(lng),
      "captured_at": ISO8601DateFormatter().string(from: capturedAt), "device_id": deviceId]
    for (name, value) in extraFields.merging(fields, uniquingKeysWith: { _, required in required }) {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"pothole.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
    body.append(jpeg); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var req = request("detections", method: "POST")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    return try await send(req)
  }

  private func pathID(_ id: String) throws -> String {
    guard let escaped = id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")), !escaped.isEmpty else {
      throw PatrolError.message("Invalid report ID.")
    }
    return escaped
  }
  private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: String]? = nil, token: String? = nil) -> URLRequest {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    let prefix = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
    components.percentEncodedPath = prefix + "/" + path
    if !query.isEmpty { components.queryItems = query }
    var req = URLRequest(url: components.url!, timeoutInterval: 30)
    req.httpMethod = method
    req.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { req.setValue(token, forHTTPHeaderField: "X-Official-Token") }
    if let json { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try? JSONEncoder().encode(json) }
    return req
  }
  private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw PatrolError.message("Unexpected server response.") }
    guard (200..<300).contains(http.statusCode) else {
      throw PatrolError.http(http.statusCode, Self.message(data: data, status: http.statusCode))
    }
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }
  private static func message(data: Data, status: Int) -> String {
    if status == 429 { return "Too many sign-in attempts. Wait a minute and try again." }
    if status == 503 { return "Backend authentication is unavailable. Ask Sanyam to check server configuration." }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if let text = object?["detail"] as? String { return text }
    if let list = object?["detail"] as? [[String: Any]], let text = list.first?["msg"] as? String { return text }
    return "Request failed (HTTP \(status)). Try again."
  }
}

/// API routes are exact. Never forward a token or captured JPEG through a redirect.
private final class APIRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
