# PotholePatrol API for the iOS app

**Conventions**
- Base URL: HTTPS only. Set it in one place in the app.
- JSON keys are snake_case. Use `decoder.keyDecodingStrategy = .convertFromSnakeCase`.
- Dates are UTC ISO 8601 with no fractions (`2026-11-07T17:50:00Z`). Use `decoder.dateDecodingStrategy = .iso8601`.
- `photo_url` is a full HTTPS URL, or null.
- Errors return a status code and `{"detail": ...}`. `detail` is text, except 422 validation errors from FastAPI, where it can be a list.

**First screen**
- Resident: no login. Create a random `device_id` once (`UUID().uuidString`) and keep it in the Keychain.
- Official: ask for the passcode, call `POST /officials/verify`, and keep the token in the Keychain.

## Resident routes

### `POST /detections` (multipart/form-data)
| Field | Type | Notes |
|---|---|---|
| `photo` | file | JPEG or PNG, up to 10 MB. HEIC is rejected, so use `UIImage.jpegData`. |
| `lat`, `lng` | number | GPS at capture time |
| `captured_at` | string | ISO 8601 |
| `device_id` | string | 8 to 128 characters |

```json
{
  "pothole_id": "3f2a...",
  "is_new": true,
  "pothole": { "...": "see Pothole below" },
  "ask_to_send": true,
  "send_plan": { "...": "see Send plan below, or null" }
}
```
If `ask_to_send` is true, offer to report it and follow `send_plan`.

### `GET /potholes`
Optional query: `agency_id`, `status` (`open`, `acknowledged`, `fixed`), `limit`. Returns `{"potholes": [Pothole]}`, newest first.

### `GET /potholes/{id}`
Returns `{"pothole": Pothole, "send_plan": SendPlan or null}`.

### `POST /potholes/{id}/send`
Call this after the resident taps the agency's Submit, or finishes the email or call. The server sends nothing to the agency.
Body: `{"method": "open_form"}` (or `email`, `phone`). Returns `{"already_sent": false, "pothole": Pothole}`.

### `GET /agencies`
Returns `{"agencies": [...]}` with `id`, `name`, `channel`, `url`, `phone`, `email`, `expected_response`.

## Official routes

### `POST /officials/verify`
Body: `{"passcode": "..."}`.
- 200: `{"verified": true, "token": "..."}`
- 401: wrong passcode
- 429: too many tries, wait a minute

Send the token as the `X-Official-Token` header on the two routes below. A 401 means sign in again.

### `GET /queue`
Optional query: `agency_id`. Returns `{"potholes": [Pothole]}`, ranked highest priority first. Fixed potholes are left out.

### `PATCH /potholes/{id}/status`
Body: `{"status": "acknowledged"}` (or `open`, `fixed`). Returns `{"pothole": Pothole}`.

## Objects

### Pothole
```json
{
  "id": "3f2a...",
  "title": "Pothole on East Washington Street (US 40) near Belmar Avenue",
  "lat": 39.77309,
  "lng": -86.02417,
  "road_name": "East Washington Street (US 40)",
  "cross_street": "Belmar Avenue",
  "status": "open",
  "report_count": 2,
  "sent": false,
  "first_seen": "2026-11-07T17:50:00Z",
  "updated_at": "2026-11-07T17:50:00Z",
  "fixed_at": null,
  "photo_url": "https://example.com/photos/3f2a.jpg",
  "owner": {
    "agency_id": "indot",
    "agency_name": "Indiana Department of Transportation (INDOT)",
    "kind": "state",
    "reason": "This is on US 40, a state route, so INDOT maintains it.",
    "confidence": "high"
  },
  "priority": { "score": 23, "reporters": 2, "road_class_points": 3, "days_open_points": 0 }
}
```
`owner.kind` is `state`, `city`, `county`, `private` or `unknown`. `agency_id` and `agency_name` are null for `private` and for most `unknown`. These can also be null: `road_name`, `cross_street`, `fixed_at`, `photo_url`.

### Send plan
```json
{
  "method": "open_form",
  "agency_id": "indot",
  "agency_name": "Indiana Department of Transportation (INDOT)",
  "url": "https://indot4u.511in.org/report",
  "phone": "1-855-463-6848",
  "email": null,
  "title": "Pothole on East Washington Street (US 40) near Belmar Avenue",
  "description": "...",
  "copy_text": "...",
  "call_script": "...",
  "expected_response": "Up to 15 business days",
  "autofill_ready": false,
  "fields": [
    { "key": "location", "label": "Location", "selector": null, "required": true, "source": "location_text", "value": "..." }
  ]
}
```

| `method` | What the app does |
|---|---|
| `open_form` | Open `url` in WKWebView. If `autofill_ready` is true, fill each field by `selector`. If false, offer `copy_text`. |
| `email` | Open a prefilled email from `email.to`, `email.subject`, `email.body`. |
| `phone` | Show `call_script` and tap to call `phone`. |
| `contact_only` | Show the owner and reason. There is nothing to submit. |

**Autofill:** only Fishers has `autofill_ready` true. Use `step` and `match_label` to fill it. `backend.md` has the details. Other agencies use `copy_text`.

Fields whose `source` starts with `user.` have a null `value`. Fill those from the phone, because the server never stores resident details.
