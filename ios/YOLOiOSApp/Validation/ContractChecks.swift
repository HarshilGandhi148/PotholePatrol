import Foundation

// Standalone, synthetic URLProtocol checks. Never sends a request to the real backend.
private final class StubProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, Data))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@main
private struct ContractChecks {
  static let pothole = #"{"id":"fixture-1","title":"Contract fixture only","lat":39.957,"lng":-86.0145,"road_name":null,"cross_street":null,"status":"open","report_count":1,"sent":false,"first_seen":"2026-11-07T17:50:00Z","updated_at":"2026-11-07T18:03:53Z","fixed_at":null,"photo_url":null,"owner":{"agency_id":null,"agency_name":null,"kind":"unknown","reason":"Outside coverage","confidence":"low"},"priority":{"score":12,"reporters":1,"road_class_points":0,"days_open_points":2}}"#
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PatrolError.message(message) }
  }
  static func body(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var output = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; output.append(contentsOf: buffer.prefix(n)) }
    return output
  }
  static func main() async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
    let api = PotholeAPI(baseURL: try PotholeAPI.validatedURL("https://fixture.invalid/"), session: session)
    for invalid in ["http://fixture.invalid", "https://user:password@fixture.invalid", "https://fixture.invalid/?secret=1", "https://fixture.invalid/#token", ""] {
      do { _ = try PotholeAPI.validatedURL(invalid); throw PatrolError.message("Invalid URL was accepted") }
      catch let error as PatrolError { if error.errorDescription == "Invalid URL was accepted" { throw error } }
    }
    StubProtocol.handler = { request in
      try require(request.url?.path == "/potholes", "Wrong public route")
      try require(request.value(forHTTPHeaderField: "X-Official-Token") == nil, "Public request leaked a token")
      try require(request.value(forHTTPHeaderField: "ngrok-skip-browser-warning") == "true", "Missing ngrok header")
      return (200, Data("{\"potholes\":[\(pothole)]}".utf8))
    }
    let reports = try await api.potholes()
    try require(reports.count == 1 && reports[0].photoUrl == nil && reports[0].owner.agencyId == nil, "Nullable DTO decode failed")
    try require(reports[0].priority.daysOpenPoints == 2 && reports[0].reportCount == 1, "snake_case decode failed")
    StubProtocol.handler = { request in
      try require(request.url?.path == "/officials/verify" && request.httpMethod == "POST", "Wrong verify route")
      let json = try JSONSerialization.jsonObject(with: body(request)) as! [String: String]
      try require(json["passcode"] == "fixture-passcode-not-real", "Wrong login payload")
      return (200, Data(#"{"verified":true,"token":"fixture-token-not-real"}"#.utf8))
    }
    let login = try await api.verifyOfficial(passcode: "fixture-passcode-not-real")
    StubProtocol.handler = { request in
      try require(request.url?.path == "/queue", "Wrong queue route")
      try require(request.value(forHTTPHeaderField: "X-Official-Token") == login.token, "Protected request missing token")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
      try require(query?.contains(URLQueryItem(name: "agency_id", value: "city:example")) == true, "Agency filter encoding failed")
      return (200, Data("{\"potholes\":[\(pothole)]}".utf8))
    }
    _ = try await api.queue(token: login.token, agencyId: "city:example")
    StubProtocol.handler = { request in
      try require(request.httpMethod == "PATCH" && request.url?.path == "/potholes/fixture-1/status", "Wrong status request")
      try require(request.value(forHTTPHeaderField: "X-Official-Token") == login.token, "Status request missing token")
      let json = try JSONSerialization.jsonObject(with: body(request)) as! [String: String]
      try require(json["status"] == "fixed", "Status must be snake_case/lowercase")
      return (200, Data("{\"pothole\":\(pothole.replacingOccurrences(of: "\"status\":\"open\"", with: "\"status\":\"fixed\""))}".utf8))
    }
    let updated = try await api.setStatus(id: "fixture-1", status: .fixed, token: login.token)
    try require(updated.status == .fixed, "Status response failed")
    let captureTime = ISO8601DateFormatter().date(from: "2026-11-07T17:50:00Z")!
    StubProtocol.handler = { request in
      let data = body(request), content = String(decoding: data, as: UTF8.self)
      try require(request.url?.path == "/detections" && request.httpMethod == "POST", "Wrong upload route")
      try require(request.value(forHTTPHeaderField: "X-Official-Token") == nil, "Upload leaked official token")
      for field in ["photo", "lat", "lng", "captured_at", "device_id"] { try require(content.contains("name=\"\(field)\""), "Missing multipart field \(field)") }
      try require(content.contains("2026-11-07T17:50:00Z") && content.contains("fixture-device-0001"), "Capture timestamp/device ID changed")
      try require(content.contains("Content-Type: image/jpeg") && request.value(forHTTPHeaderField: "Content-Type")?.contains("boundary=Boundary-") == true, "Wrong multipart content type")
      return (200, Data("{\"pothole_id\":\"fixture-1\",\"is_new\":false,\"pothole\":\(pothole),\"ask_to_send\":false,\"send_plan\":null}".utf8))
    }
    let upload = try await api.postDetection(jpeg: Data([0xff,0xd8,0xff,0xd9]), lat: 39.957, lng: -86.0145, capturedAt: captureTime, deviceId: "fixture-device-0001")
    try require(!upload.isNew && upload.sendPlan == nil, "Detection response decode failed")
    for code in [401, 429, 503, 422] {
      StubProtocol.handler = { _ in (code, Data(#"{"detail":[{"msg":"fixture error"}]}"#.utf8)) }
      do { _ = try await api.queue(token: login.token); throw PatrolError.message("HTTP error accepted") }
      catch let error as PatrolError { try require(error.status == code, "Lost HTTP status") }
    }
    print("PASS: DTO/null/date decoding; HTTPS configuration; public/protected headers; login, queue, status, multipart, and HTTP error contracts. No live network requests.")
  }
}
