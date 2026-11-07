import Foundation

enum PotholeStatus: String, Codable, CaseIterable, Identifiable {
  case open, acknowledged, fixed
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

struct Owner: Codable {
  let agencyId: String?
  let agencyName: String?
  let kind: String
  let reason: String
  let confidence: String
  var isPublic: Bool { ["state", "city", "county"].contains(kind) && agencyId != nil }
}
struct Priority: Codable {
  let score: Int
  let reporters: Int
  let roadClassPoints: Int
  let daysOpenPoints: Int
}
struct Pothole: Codable, Identifiable {
  let id: String
  let title: String
  let lat: Double
  let lng: Double
  let roadName: String?
  let crossStreet: String?
  let status: PotholeStatus
  let reportCount: Int
  let sent: Bool
  let firstSeen: Date
  let updatedAt: Date
  let fixedAt: Date?
  let photoUrl: URL?
  let owner: Owner
  let priority: Priority
}
struct EmailDraft: Codable { let to: String?; let subject: String; let body: String }
struct FormField: Codable {
  let key: String
  let label: String
  let step: Int?
  let matchLabel: String?
  let selector: String?
  let required: Bool
  let source: String
  let value: String?
}
struct SendPlan: Codable {
  let method: String
  let agencyId: String?
  let agencyName: String?
  let url: URL?
  let phone: String?
  let email: EmailDraft?
  let title: String
  let description: String
  let copyText: String
  let callScript: String?
  let expectedResponse: String?
  let autofillReady: Bool
  let instructions: [String]?
  let fields: [FormField]
}
struct Agency: Codable, Identifiable {
  let id: String
  let name: String
  let channel: String
  let url: URL?
  let phone: String?
  let email: String?
  let expectedResponse: String?
}
struct DetectionResponse: Codable {
  let potholeId: String
  let isNew: Bool
  let pothole: Pothole
  let askToSend: Bool
  let sendPlan: SendPlan?
}
struct PotholeDetail: Codable { let pothole: Pothole; let sendPlan: SendPlan? }
struct SendResponse: Codable { let alreadySent: Bool; let pothole: Pothole }
struct PotholeList: Codable { let potholes: [Pothole] }
struct AgencyList: Codable { let agencies: [Agency] }
struct PotholeWrapper: Codable { let pothole: Pothole }
struct VerifyResponse: Codable { let verified: Bool; let token: String }
struct HealthResponse: Codable { let status: String }

enum PatrolError: LocalizedError {
  case message(String)
  case http(Int, String)
  var errorDescription: String? {
    switch self { case .message(let text), .http(_, let text): return text }
  }
  var status: Int? { if case .http(let status, _) = self { return status }; return nil }
}
