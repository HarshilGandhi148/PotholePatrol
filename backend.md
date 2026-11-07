# PotholePatrol backend guide for the frontend

Everything you need to connect the app to the backend. All example responses come from the running API, and the Swift client in section 8 was run against it.

**Ask Sanyam for two things, which are not in this public repo:**
1. The HTTPS base URL.
2. The officials passcode.

Use `BASE_URL` wherever you see it below.

## Contents

1. [What the backend does](#1-what-the-backend-does)
2. [Rules for every request](#2-rules-for-every-request)
3. [Which screen calls what](#3-which-screen-calls-what)
4. [Resident routes](#4-resident-routes)
5. [Official routes](#5-official-routes)
6. [Data objects](#6-data-objects)
7. [Sending a report to an agency](#7-sending-a-report-to-an-agency)
8. [Swift client](#8-swift-client)
9. [Sending detections from the YOLO app](#9-sending-detections-from-the-yolo-app)
10. [Errors](#10-errors)
11. [Test data](#11-test-data)
12. [If you use the React frontend](#12-if-you-use-the-react-frontend)
13. [Not ready yet](#13-not-ready-yet)

## 1. What the backend does

The phone sends a pothole photo and its location. The backend then:

1. Strips all EXIF data from the photo.
2. Merges it with an existing pothole if there's one on the same road within 25 m.
3. Works out who owns the road: INDOT, a city or town, the county, or a private owner.
4. Names it by location, such as "Pothole on East Washington Street (US 40) near Belmar Avenue".
5. Scores it by how many different devices reported it.
6. Tells the app whether to ask the resident to report it, and how.

**The backend never contacts an agency.** The app opens the agency's real page and the resident taps the agency's own Submit.

**Coverage:** road lookups work across Indianapolis (all of Marion County) and Fishers. Anywhere else, the API still responds, but the owner comes back as `unknown`.

## 2. Rules for every request

| Rule | Detail |
|---|---|
| Transport | HTTPS only |
| JSON keys | snake_case |
| Dates | UTC ISO 8601 with no fractions: `2026-11-07T17:50:00Z` |
| IDs | Strings. Treat them as opaque. |
| Photos | `photo_url` is a full HTTPS URL, or `null`. Photo URLs need no sign-in. |
| Resident routes | No sign-in |
| Official routes | Need the `X-Official-Token` header |
| Null values | Fields marked nullable are present with the value `null` |
| Updates | There are no push updates. Refresh on screen open and on pull to refresh. |

**If the base URL is an ngrok address,** add this header to every request. It stops ngrok returning its warning page:

```text
ngrok-skip-browser-warning: true
```

**Check the connection:**

```bash
curl https://BASE_URL/health
```

```json
{"status":"ok"}
```

## 3. Which screen calls what

| Screen | What it does | Call |
|---|---|---|
| First screen | Choose Resident or Official | None |
| Resident: scan | Send each new pothole | `POST /detections` |
| Resident: "Report this?" prompt | Shown when `ask_to_send` is true | Uses `send_plan` from the response |
| Resident: agency page | Open the form in WKWebView | None, then `POST /potholes/{id}/send` |
| Resident: map | Show all potholes | `GET /potholes` |
| Resident: pothole detail | Status, owner, reason, report options | `GET /potholes/{id}` |
| Resident: my reports | Save `pothole_id` values on the phone, then load each one | `GET /potholes/{id}` |
| Official: sign in | Enter passcode | `POST /officials/verify` |
| Official: ranked list | Highest priority first | `GET /queue` |
| Official: agency filter | Fill the picker | `GET /agencies` |
| Official: map | Same data as the resident map | `GET /potholes` |
| Official: mark fixed | Update status | `PATCH /potholes/{id}/status` |

There's no "my reports" route, because the backend can't link a device to its potholes. That's deliberate, so a drive can't be rebuilt from the data.

## 4. Resident routes

### `POST /detections`

Sends one pothole. Use `multipart/form-data`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `photo` | file | Yes | JPEG or PNG, up to 10 MB. HEIC and video are rejected. |
| `lat` | number | Yes | -90 to 90 |
| `lng` | number | Yes | -180 to 180 |
| `captured_at` | string | Yes | ISO 8601 with a time zone. Can't be over a day in the future. |
| `device_id` | string | Yes | 8 to 128 characters. Create it once and reuse it. |

```bash
curl -X POST https://BASE_URL/detections \
  -F photo=@pothole.jpg \
  -F lat=39.77309 \
  -F lng=-86.02417 \
  -F captured_at=2026-11-07T17:50:00Z \
  -F device_id=7F3A9C10-2B44-4E0B-9A11-0C1D2E3F4A5B
```

Response `200`:

```json
{
  "pothole_id": "3f2a9c104e0b4b1d8a11c1d2e3f4a5b6",
  "is_new": true,
  "pothole": { "see": "Pothole in section 6" },
  "ask_to_send": true,
  "send_plan": { "see": "Send plan in section 6" }
}
```

| Field | Meaning |
|---|---|
| `pothole_id` | Save this on the phone for "my reports" |
| `is_new` | `true` if this created a pothole, `false` if it merged into one |
| `ask_to_send` | `true` means ask the resident to report it now |
| `send_plan` | Instructions for reporting. `null` when `ask_to_send` is false. |

Behaviour to know about:

- **Retries are safe.** The same device on the same pothole counts once, so resend if a request fails.
- **Only the first photo is kept** for each pothole.
- **`ask_to_send` needs enough devices.** The threshold is a server setting: 1 for the demo, 3 by default.
- **It stops asking** once any resident has marked the pothole as sent.
- **It never asks** for private roads or unknown owners.
- **A fixed pothole is closed.** A new detection in the same place creates a new pothole.

### `GET /potholes`

Lists potholes, newest first. Fixed potholes are included unless you filter them out.

| Query | Type | Default | Notes |
|---|---|---|---|
| `agency_id` | string | None | For example `indot` |
| `status` | string | None | `open`, `acknowledged` or `fixed`. One value only. |
| `limit` | integer | 500 | 1 to 1000 |

```bash
curl "https://BASE_URL/potholes?status=open&limit=100"
```

Response `200`:

```json
{ "potholes": [ { "see": "Pothole in section 6" } ] }
```

For a map of open and acknowledged potholes, call it with no `status` and hide `fixed` on the phone.

### `GET /potholes/{id}`

Gets one pothole and its current send plan.

Response `200`:

```json
{
  "pothole": { "see": "Pothole in section 6" },
  "send_plan": { "see": "Send plan in section 6" }
}
```

`send_plan` is `null` when no public agency owns the road. Unlike in `POST /detections`, it's returned here whenever an agency exists, so a resident can report from the detail screen at any time.

### `POST /potholes/{id}/send`

Records that the resident reported it, so nobody else gets asked. Call it after they finish on the agency's page, email or phone call. **This doesn't send anything to the agency.**

```json
{ "method": "open_form" }
```

`method` is `open_form`, `email` or `phone`. Don't call this route for `contact_only`.

Response `200`:

```json
{
  "already_sent": false,
  "pothole": { "see": "Pothole in section 6" }
}
```

`already_sent` is `true` if someone reported it first. That isn't an error. A pothole with no public agency returns `409`.

### `GET /agencies`

Lists the three agencies with full reporting support.

```json
{
  "agencies": [
    {
      "id": "city:indianapolis",
      "name": "City of Indianapolis",
      "channel": "webform",
      "url": "https://request.indy.gov/",
      "phone": "317-327-4622",
      "email": null,
      "expected_response": null
    }
  ]
}
```

The IDs are `city:indianapolis`, `city:fishers` and `indot`. `channel` is `webform` today, and could also be `email` or `phone`.

### `GET /health`

Returns `{"status":"ok"}`. Use it to check the server is up.

## 5. Official routes

### `POST /officials/verify`

Swaps the passcode for a token.

```json
{ "passcode": "the-passcode" }
```

| Status | Meaning | What the app does |
|---|---|---|
| `200` | Correct | Store the token and show the officials' screens |
| `401` | Wrong passcode | Show "Wrong passcode" |
| `429` | 10 wrong tries in a minute, from anyone | Show "Wait a minute and try again" |
| `503` | No passcode set on the server | Tell Sanyam |

Response `200`:

```json
{ "verified": true, "token": "9b1f0c..." }
```

Store the token in the Keychain, not the passcode. Send it on the two routes below:

```text
X-Official-Token: 9b1f0c...
```

The token doesn't expire, but it stops working if the passcode changes. On any `401`, send the user back to the sign-in screen.

### `GET /queue`

The ranked list. It leaves out fixed potholes and potholes with no agency. Ties go to the oldest.

| Query | Type | Notes |
|---|---|---|
| `agency_id` | string | Optional. Leave it out for all agencies. |

```bash
curl -H "X-Official-Token: TOKEN" "https://BASE_URL/queue?agency_id=city:fishers"
```

Response `200`:

```json
{ "potholes": [ { "see": "Pothole in section 6" } ] }
```

### `PATCH /potholes/{id}/status`

```json
{ "status": "fixed" }
```

`status` is `open`, `acknowledged` or `fixed`. Sending `open` or `acknowledged` on a fixed pothole reopens it.

Response `200`:

```json
{ "pothole": { "see": "Pothole in section 6" } }
```

Residents see the change the next time they load that pothole.

## 6. Data objects

### Pothole

A real response:

```json
{
  "id": "f0d3c965928941f6b3788903c0f4ca36",
  "title": "Pothole on Massachusetts Avenue near East New York Street",
  "lat": 39.7719,
  "lng": -86.15338,
  "road_name": "Massachusetts Avenue",
  "cross_street": "East New York Street",
  "status": "open",
  "report_count": 1,
  "sent": false,
  "first_seen": "2026-11-07T17:50:00Z",
  "updated_at": "2026-11-07T19:03:24Z",
  "fixed_at": null,
  "photo_url": "https://BASE_URL/photos/f0d3c965928941f6b3788903c0f4ca36.jpg",
  "owner": {
    "agency_id": "city:indianapolis",
    "agency_name": "City of Indianapolis",
    "kind": "city",
    "reason": "This is inside City of Indianapolis limits and is not a state road.",
    "confidence": "high"
  },
  "priority": {
    "score": 12,
    "reporters": 1,
    "road_class_points": 2,
    "days_open_points": 0
  }
}
```

| Field | Type | Nullable | Meaning |
|---|---|---|---|
| `id` | string | No | Pothole ID |
| `title` | string | No | Display name. It's factual and has no severity. |
| `lat`, `lng` | number | No | Location |
| `road_name` | string | Yes | Includes the route if there is one, such as `East Washington Street (US 40)` |
| `cross_street` | string | Yes | Nearest other road within 300 m |
| `status` | string | No | `open`, `acknowledged` or `fixed` |
| `report_count` | integer | No | Distinct devices |
| `sent` | boolean | No | Has a resident reported it to the agency? |
| `first_seen` | date | No | First capture time |
| `updated_at` | date | No | Last change |
| `fixed_at` | date | Yes | When an official marked it fixed |
| `photo_url` | string | Yes | Always handle `null` |
| `owner` | object | No | See below |
| `priority` | object | No | See below |

### Owner

| Field | Type | Nullable | Meaning |
|---|---|---|---|
| `agency_id` | string | Yes | `null` for private roads and most unknown owners |
| `agency_name` | string | Yes | Display name |
| `kind` | string | No | `state`, `city`, `county`, `private` or `unknown` |
| `reason` | string | No | Plain-English explanation. Show this to residents. |
| `confidence` | string | No | `high`, `medium` or `low` |

| `kind` | What to show |
|---|---|
| `state` | INDOT owns it, even inside a city |
| `city` | The city or town owns it |
| `county` | The county owns it |
| `private` | No public agency. Show `reason`, with no report button. |
| `unknown` | Show `reason`. It's either outside coverage, or too far from a road. |

`medium` means the pin is 15 to 30 m from the road, or at an intersection of roads with different owners, or on a private road. `low` means the owner is unknown. For `medium`, it's worth asking the resident to check the road name.

### Priority

| Field | Meaning |
|---|---|
| `score` | Sort by this, highest first |
| `reporters` | Distinct devices. Each is worth 10 points. |
| `road_class_points` | 0 to 3. Bigger roads score higher. |
| `days_open_points` | 0 to 3. One point per 10 days open. |

`score = reporters × 10 + road_class_points + days_open_points`. Show the breakdown so officials can see why something ranks where it does. Tie-breakers add at most 6, so one more reporter always ranks higher.

### Send plan

A real response:

```json
{
  "method": "open_form",
  "agency_id": "city:indianapolis",
  "agency_name": "City of Indianapolis",
  "url": "https://request.indy.gov/",
  "phone": "317-327-4622",
  "email": null,
  "title": "Pothole on Massachusetts Avenue near East New York Street",
  "description": "Pothole on Massachusetts Avenue near East New York Street. GPS 39.77190, -86.15338. 1 report through PotholePatrol, first seen 2026-11-07.",
  "copy_text": "Pothole on Massachusetts Avenue near East New York Street\nPothole on Massachusetts Avenue near East New York Street. GPS 39.77190, -86.15338. 1 report through PotholePatrol, first seen 2026-11-07.",
  "call_script": "I'd like to report a pothole. Pothole on Massachusetts Avenue near East New York Street. GPS 39.77190, -86.15338. 1 report through PotholePatrol, first seen 2026-11-07.",
  "expected_response": null,
  "autofill_ready": false,
  "fields": [
    {
      "key": "location",
      "label": "Location",
      "selector": null,
      "required": true,
      "source": "location_text",
      "value": "Massachusetts Avenue near East New York Street (39.77190, -86.15338)"
    }
  ]
}
```

| Field | Type | Nullable | Meaning |
|---|---|---|---|
| `method` | string | No | `open_form`, `email`, `phone` or `contact_only` |
| `agency_id`, `agency_name` | string | Yes | Who it goes to |
| `url` | string | Yes | Page to open |
| `phone` | string | Yes | Number to call |
| `email` | object | Yes | `{ "to", "subject", "body" }` for the `email` method |
| `title`, `description` | string | No | Factual text about the pothole |
| `copy_text` | string | No | Title and description, ready to copy |
| `call_script` | string | Yes | What to say on a call. Present when the agency has a phone number. |
| `expected_response` | string | Yes | Typical wait |
| `autofill_ready` | boolean | No | `true` only once the form has been tested |
| `fields` | array | No | Form fields. Empty for `contact_only`. |

Each item in `fields`:

| Field | Type | Nullable | Meaning |
|---|---|---|---|
| `key` | string | No | Our name for the field |
| `label` | string | No | Label to show |
| `selector` | string | Yes | CSS selector on the agency's page. All `null` for now. |
| `required` | boolean | No | Does the agency need it? |
| `source` | string | No | Where the value comes from |
| `value` | string | Yes | Value to fill in |

## 7. Sending a report to an agency

Follow `send_plan.method`:

| `method` | What the app does |
|---|---|
| `open_form` | Open `url` in WKWebView and show `copy_text` with a Copy button |
| `email` | Open a prefilled email using `email.to`, `email.subject` and `email.body` |
| `phone` | Show `call_script` and a tap-to-call button for `phone` |
| `contact_only` | Show the agency name and `owner.reason`, with no send option |

**`open_form` steps:**

1. Show the pothole title and `expected_response`.
2. Open `url` in WKWebView.
3. If `autofill_ready` is `false`, offer `copy_text`. **This is the case for every agency today.**
4. If `autofill_ready` is `true`, fill each field that has a `selector`.
5. The resident checks the form and taps the agency's own Submit. **Never tap Submit from code.**
6. Show an "I submitted it" button. The app can't detect the agency's Submit.
7. When they tap it, call `POST /potholes/{id}/send`.

**Things to know:**

- **A site may ask residents to sign in.** That isn't confirmed for Request Indy or Fishers Connect yet. If one does, the resident signs in on the page. Don't handle their password in our app.
- **`user.*` fields stay on the phone.** If `source` starts with `user.`, such as `user.first_name`, `value` is `null`. Fill it from the phone, because the server stores no resident details.
- **Photos can't be autofilled.** JavaScript can't set a file input, so the resident attaches the photo on the page.
- **Don't test with real submissions.** Stop before Submit, so test reports never reach real staff.

**Needed from you:** test each form in WKWebView and send Sanyam the results for each agency:

- Does the page load in WKWebView?
- What's the CSS selector for each field?
- Which fields are required?
- Does it accept a photo?

Those results turn on `autofill_ready`. No app change should be needed if you've built step 4.

## 8. Swift client

Copy this into a file such as `PotholeAPI.swift`. It uses only Foundation.

Two decoder details matter:
- `.convertFromSnakeCase` turns `photo_url` into `photoUrl`, not `photoURL`. Keep the property names as they are here.
- `.iso8601` fails on dates with fractions. The API never sends fractions.

```swift
import Foundation

enum PotholeStatus: String, Codable {
    case open, acknowledged, fixed
}

struct Owner: Codable {
    let agencyId: String?
    let agencyName: String?
    let kind: String
    let reason: String
    let confidence: String
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

struct EmailDraft: Codable {
    let to: String?
    let subject: String
    let body: String
}

struct FormField: Codable {
    let key: String
    let label: String
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

struct PotholeDetail: Codable {
    let pothole: Pothole
    let sendPlan: SendPlan?
}

struct SendResponse: Codable {
    let alreadySent: Bool
    let pothole: Pothole
}

private struct PotholeList: Codable { let potholes: [Pothole] }
private struct AgencyList: Codable { let agencies: [Agency] }
private struct PotholeWrapper: Codable { let pothole: Pothole }
private struct VerifyResponse: Codable { let verified: Bool; let token: String }

enum APIError: LocalizedError {
    case http(status: Int, message: String)
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .http(_, let message): return message
        case .notHTTP: return "The server sent an unexpected response."
        }
    }

    var status: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }
}

/// A random id, created once. It only tells the server that two reports came from different phones.
enum DeviceID {
    static var current: String {
        let key = "pothole_device_id"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

final class PotholeAPI {
    let baseURL: URL
    /// Set after verifyOfficial. Keep it in the Keychain between launches.
    var officialToken: String?

    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Resident

    /// jpeg: use image.jpegData(compressionQuality: 0.8). HEIC is rejected.
    func postDetection(jpeg: Data, lat: Double, lng: Double, capturedAt: Date = Date()) async throws -> DetectionResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let fields = [
            "lat": String(lat),
            "lng": String(lng),
            "captured_at": ISO8601DateFormatter().string(from: capturedAt),
            "device_id": DeviceID.current,
        ]
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"pothole.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = makeRequest("detections", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request)
    }

    func potholes(agencyId: String? = nil, status: PotholeStatus? = nil, limit: Int = 500) async throws -> [Pothole] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let agencyId { query.append(URLQueryItem(name: "agency_id", value: agencyId)) }
        if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        let list: PotholeList = try await send(makeRequest("potholes", query: query))
        return list.potholes
    }

    func pothole(id: String) async throws -> PotholeDetail {
        try await send(makeRequest("potholes/\(id)"))
    }

    /// Call after the resident finishes reporting. method: "open_form", "email" or "phone".
    func markSent(id: String, method: String) async throws -> SendResponse {
        try await send(makeRequest("potholes/\(id)/send", method: "POST", json: ["method": method]))
    }

    func agencies() async throws -> [Agency] {
        let list: AgencyList = try await send(makeRequest("agencies"))
        return list.agencies
    }

    // MARK: Officials

    func verifyOfficial(passcode: String) async throws {
        let response: VerifyResponse = try await send(
            makeRequest("officials/verify", method: "POST", json: ["passcode": passcode])
        )
        officialToken = response.token
    }

    func queue(agencyId: String? = nil) async throws -> [Pothole] {
        let query = agencyId.map { [URLQueryItem(name: "agency_id", value: $0)] } ?? []
        let list: PotholeList = try await send(makeRequest("queue", query: query))
        return list.potholes
    }

    func setStatus(id: String, status: PotholeStatus) async throws -> Pothole {
        let wrapper: PotholeWrapper = try await send(
            makeRequest("potholes/\(id)/status", method: "PATCH", json: ["status": status.rawValue])
        )
        return wrapper.pothole
    }

    // MARK: Plumbing

    private func makeRequest(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        json: [String: String]? = nil
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let officialToken { request.setValue(officialToken, forHTTPHeaderField: "X-Official-Token") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(json)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: Self.message(from: data))
        }
        return try decoder.decode(T.self, from: data)
    }

    /// `detail` is text, except for validation errors, where it's a list.
    private static func message(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let text = object?["detail"] as? String { return text }
        if let list = object?["detail"] as? [[String: Any]], let first = list.first?["msg"] as? String { return first }
        return "Something went wrong. Try again."
    }
}
```

Usage:

```swift
let api = PotholeAPI(baseURL: URL(string: "https://BASE_URL")!)

let result = try await api.postDetection(jpeg: jpegData, lat: 39.77309, lng: -86.02417)
print(result.pothole.title, result.pothole.owner.reason)
if result.askToSend, let plan = result.sendPlan {
    // Show the "Report this?" prompt, then follow plan.method.
}

try await api.verifyOfficial(passcode: enteredPasscode)
let ranked = try await api.queue()
```

## 9. Sending detections from the YOLO app

This section is for connecting the existing iOS detection code. The app's `Info.plist` needs an `NSLocationWhenInUseUsageDescription` entry for location access.

1. **Get results** from `YOLOView`'s `onDetection` callback.
2. **Keep potholes only.** The model also finds three crack classes, so skip anything where the class isn't `pothole`.
3. **Add GPS yourself.** `YOLOResult` has no location, so read it from Core Location at the moment of the frame. Skip frames with poor accuracy (`horizontalAccuracy` over about 20 m).
4. **Use the matching photo.** Enable `originalImage` so the photo matches the detection. For a gallery photo, use the location and time stored in that photo, never the phone's current GPS.
5. **Send one request per pothole.** `onDetection` fires for many frames. Don't send again until the phone has moved more than 25 m from the last pothole you sent. The server merges duplicates, but this saves uploads.
6. **Send JPEG.** Use `image.jpegData(compressionQuality: 0.8)`.
7. **Handle no signal.** Queue detections on the phone with their real `captured_at`, then send them later. Retries are safe.

Please don't:

- Send a continuous GPS track. Send pothole locations only.
- Add a severity field or label. Potholes are named by location and ranked by reporter count.
- Send names or contact details to the backend.

## 10. Errors

Errors have a status code and a `detail` field:

```json
{ "detail": "Pothole not found" }
```

For `422` from form or JSON validation, `detail` is a list. Use `msg` from the first item:

```json
{
  "detail": [
    {
      "type": "less_than_equal",
      "loc": ["body", "lat"],
      "msg": "Input should be less than or equal to 90",
      "input": "95",
      "ctx": { "le": 90.0 }
    }
  ]
}
```

| Status | Route | Meaning | What the app does |
|---|---|---|---|
| `401` | `/queue`, `/potholes/{id}/status` | Missing or bad token | Go to the officials' sign-in |
| `401` | `/officials/verify` | Wrong passcode | Show "Wrong passcode" |
| `404` | Any `/potholes/{id}` route | No such pothole | Show "Pothole not found" and remove it from "my reports" |
| `409` | `/potholes/{id}/send` | No public agency owns the road | Hide the report option |
| `413` | `/detections` | Photo is over 10 MB | Compress it and retry |
| `422` | Any | Bad input, an unreadable photo, or a date in the future | Fix the request. Don't retry unchanged. |
| `429` | `/officials/verify` | Too many wrong passcodes | Ask them to wait a minute |
| `503` | `/officials/verify` | Passcode isn't set on the server | Tell Sanyam |
| No response | Any | Server is off or there's no signal | Retry later |

## 11. Test data

These locations give known results. Test with your own JPEG:

| Place | `lat`, `lng` | `agency_id` | Title |
|---|---|---|---|
| East Washington Street, outside I-465 | `39.77309, -86.02417` | `indot` | Pothole on East Washington Street (US 40) near Belmar Avenue |
| East Washington Street, downtown | `39.76689, -86.14951` | `city:indianapolis` | Pothole on East Washington Street near North East Street |
| Massachusetts Avenue | `39.7719, -86.15338` | `city:indianapolis` | Pothole on Massachusetts Avenue near East New York Street |
| East 116th Street, Fishers | `39.95684, -86.02938` | `city:fishers` | Pothole on East 116th Street near Madden Drive |
| SR 37, Fishers | `39.98069, -86.00374` | `indot` | Pothole on IN-37 (SR 37) near Market Square Drive |
| I-465 ramp | `39.82361, -86.27579` | `indot` | Pothole on I 465 near West 38th Street |
| East 56th Street, Lawrence | `39.85582, -85.97718` | `city:lawrence` | Pothole on East 56th Street near Grosbeak Lane |

Lawrence isn't one of the three agencies, so its plan is `contact_only`. The same goes for Speedway, Beech Grove and Southport.

**Test each state:**
- **New pothole:** post to a location above.
- **Merged pothole:** post to the same place with a different `device_id`. Expect `is_new: false` and `report_count: 2`.
- **Same device:** post again with the same `device_id`. `report_count` stays the same.
- **Outside coverage:** post from `41.0793, -85.1394` (Fort Wayne). Expect `owner.kind: "unknown"` and "We don't cover this area yet."

**Demo story:** East Washington Street changes owner at I-465. Inside it's a City of Indianapolis street, and outside it's US 40, so it goes to INDOT.

**Existing data:** the database starts empty. Test detections stay in it, so tell Sanyam when you want them cleared before the demo.

## 12. If you use the React frontend

The plan is iOS, with resident and official views in the same app. `AkshanshBranch` also has a React frontend that runs on mock data. **Connecting it needs one backend change first:** the API doesn't allow browser calls from other sites yet (CORS). Tell Sanyam the site's address and it can be added.

The API's shape differs from `frontend/src/types/index.ts`:

| React frontend | Backend | What to do |
|---|---|---|
| `latitude`, `longitude` | `lat`, `lng` | Rename |
| `address` | `title`, `road_name`, `cross_street` | Use `title` |
| `status: 'Open'` | `status: 'open'` | Convert to lowercase when sending |
| `severity` | None | Remove it. The project doesn't use severity ratings. |
| `safetyHazard` | None | Remove it |
| Triage score, max 95 | `priority.score` | Use the backend score and its breakdown |
| `agencyId` | `owner.agency_id` | Rename |
| `POST /v1/detection-sessions` (proposed) | `POST /detections` | Use the backend route, one photo per request |
| `POST /v1/reports` (proposed) | `POST /detections` | The backend has no separate report step |
| Video upload, 150 MB | Not supported | Send a JPEG or PNG frame, up to 10 MB |
| Photo limit 20 MB | 10 MB | Lower the limit |
| 44 Indianapolis and Fishers demo records | Real detections only | Remove the mock records. The area already matches. |
| JSON detection import | Not supported | Send each pothole to `POST /detections` |
| Status edits stored locally | `PATCH /potholes/{id}/status` | Call the API with the official token |

Keep API calls in `src/services/`, as `frontend/AGENTS.md` says. Set `VITE_API_BASE_URL` to the base URL.

## 13. Not ready yet

| Item | Status | Who |
|---|---|---|
| HTTPS base URL | Sanyam will share it. It may change if the server restarts. | Sanyam |
| Form autofill | All fields are placeholders until the WKWebView tests are done. Use `copy_text`. | Frontend, then Sanyam |
| Fishers form | `url` is the Fishers Connect page. It blocks automated checks, so open it in a real browser to confirm it. | Frontend or Sanyam |
| Demo data | The database starts empty. There's no public Indianapolis data to import. | Sanyam |
| Backend code | Not in this repo yet | Sanyam |
| iPhone testing | The API hasn't been tested from a real iPhone or over HTTPS | Everyone |
| Real accounts | Not planned for MVP 1. Officials share one passcode. | MVP 2 |
| Video upload | Not supported | MVP 2 |
| Push notifications | Not supported. Refresh instead. | MVP 2 |
