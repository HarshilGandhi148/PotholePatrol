import Foundation
import Combine
import CoreLocation
import Security
import UIKit

/// Random, per-install identifier. No device fingerprint or personal identifier is read.
enum DeviceIdentity {
  static var current: String {
    let key = "patrol.deviceID"
    if let id = UserDefaults.standard.string(forKey: key) { return id }
    let id = UUID().uuidString; UserDefaults.standard.set(id, forKey: key); return id
  }
}

enum CredentialStore {
  private static func query(server: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "PotholePatrol.official",
     kSecAttrAccount as String: server]
  }
  static func read(server: String) -> String? {
    var q = query(server: server); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ token: String, server: String) throws {
    remove(server: server)
    var q = query(server: server); q[kSecValueData as String] = Data(token.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw PatrolError.message("Unable to store the official session securely.") }
  }
  static func remove(server: String) { SecItemDelete(query(server: server) as CFDictionary) }
}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var location: CLLocation?
  @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
  @Published private(set) var message = "Location not requested"
  private let manager = CLLocationManager()
  private var scanning = false
  private var requestOnceAfterAuthorization = false
  override init() {
    super.init(); authorization = manager.authorizationStatus; manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.distanceFilter = 10
  }
  func startScanning() {
    scanning = true
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation(); message = "Acquiring GPS…"
    default: message = "Location denied. Confirm a position manually."
    }
  }
  func stop() { scanning = false; requestOnceAfterAuthorization = false; manager.stopUpdatingLocation() }
  func retry() {
    switch manager.authorizationStatus {
    case .notDetermined: requestOnceAfterAuthorization = true; manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation(); message = "Requesting a fresh position…"
    default: message = "Enable location in iOS Settings or choose a position manually."
    }
  }
  func freshLocation(at time: Date) -> CLLocation? {
    guard let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 20,
      abs(location.timestamp.timeIntervalSince(time)) <= 15 else { return nil }
    return location
  }
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in self?.authorizationChanged() }
  }
  private func authorizationChanged() {
    authorization = manager.authorizationStatus
    if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
      if scanning { manager.startUpdatingLocation() }
      else if requestOnceAfterAuthorization { requestOnceAfterAuthorization = false; manager.requestLocation() }
    } else if authorization == .denied || authorization == .restricted { message = "Location unavailable. Manual confirmation required." }
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
    Task { @MainActor [weak self] in self?.received(latest) }
  }
  private func received(_ latest: CLLocation) {
    location = latest
    message = latest.horizontalAccuracy <= 20 ? "GPS ±\(Int(latest.horizontalAccuracy)) m" : "GPS accuracy ±\(Int(latest.horizontalAccuracy)) m · confirm manually"
  }
  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor [weak self] in self?.message = "Unable to obtain a fresh position. Retry or choose it on the map." }
  }
}

/// A single user-captured observation, never a continuous frame/location history.
struct PendingObservation: Codable, Identifiable {
  let id: UUID
  let capturedAt: Date
  var lat: Double?
  var lng: Double?
  var accuracyMeters: Double?
  var locationConfirmed: Bool
  let jpeg: Data
  var backendURL: String?
}

enum ObservationStorage {
  static func fileURL() throws -> URL {
    let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("PotholePatrol", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var excluded = dir; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
    return dir.appendingPathComponent("pending-observation.json")
  }
  static func load() throws -> PendingObservation? {
    let url = try fileURL(); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(PendingObservation.self, from: Data(contentsOf: url))
  }
  static func save(_ observation: PendingObservation) throws {
    try JSONEncoder().encode(observation).write(to: fileURL(), options: [.atomic, .completeFileProtection])
  }
  static func remove() throws {
    let url = try fileURL(); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
  static func jpeg(from image: UIImage) throws -> Data {
    let scale = min(1, 1920 / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    for quality in [0.85, 0.65, 0.45, 0.25] {
      if let data = rendered.jpegData(compressionQuality: quality), data.count <= 10 * 1024 * 1024 { return data }
    }
    throw PatrolError.message("Unable to prepare a JPEG under 10 MB. Retake the photo.")
  }
}
