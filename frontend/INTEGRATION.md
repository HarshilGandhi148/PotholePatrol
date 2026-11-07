# Frontend integration guide — MVP 2

## Scope and verified sources

This React/Vite frontend works without a backend. It captures/uploads browser media, previews explicitly simulated analysis, imports JSON model output, prepares reports locally, and shares reports across the resident map and maintenance queue. It does not run Core ML/Python inference, determine depth or verified severity, establish road ownership, submit 311 requests, verify repairs, track objects, or synchronize official status.

Inspected `origin/main` at `9806571` using Git references, without switching or merging:

- `desktop/webcam.py`: `model.predict(...)[0]`, `result.boxes`, `box.xyxy[0]`, `box.cls[0]`, `box.conf[0]`, and `model.names`. This is a webcam/OpenCV application, not an HTTP server.
- `ios/Sources/UltralyticsYOLO/YOLOResult.swift`: `YOLOResult.boxes`, `orig_shape`, optional original/annotated images; `Box.cls`, `conf`, `xywh`, `xywhn`.
- `ios/Sources/UltralyticsYOLO/YOLOView.swift`: `onDetection: ((YOLOResult) -> Void)?` and the delegate `yoloView(_:didReceiveResult:)`. These callbacks fire during prediction.
- `ios/Sources/UltralyticsYOLO/ObjectDetector.swift`: Vision boxes are converted to top-left coordinates (`y = 1 - maxY`) before being stored as `xywhn`. Do not flip them again in the exporter for this code path.
- Model metadata in `ios/YOLOiOSApp/Models/Detect/best.mlpackage/Data/com.apple.CoreML/Metadata.json` lists `longitudinal_crack`, `transverse_crack`, `alligator_crack`, `pothole` in indices 0–3.

No model, iOS, desktop, or backend files were changed. The JSON envelope below is a proposed export contract, not the native Swift output structure.

## Structure and exact integration points

| File | Responsibility / future integration change |
| --- | --- |
| `src/App.tsx` | Router, workspace navigation, Resident/Official switch, reset action |
| `src/components/Explorer.tsx` | Map filters, region selector, queue tabs/table, actual-state metrics, selected report summary |
| `src/components/RoadMap.tsx` | Leaflet tiles/markers, explicit region fitBounds, resize handling, coordinate picker |
| `src/components/Media.tsx` | Native browser capture/upload, MediaRecorder lifecycle, preview/removal |
| `src/components/Detections.tsx` | Import input/errors, candidate list, saved-candidate guard |
| `src/components/ReportFlow.tsx` | Capture → detection review → location/severity confirmation → local save |
| `src/components/Reports.tsx` | Shared report drawer, score breakdown, simulated status/severity controls |
| `src/types/index.ts` | Shared `PotholeReport`, `DetectionResult`, `DetectionLocation`, `AnalysisResult`, `ReportDraft`, `Agency`, `SubmissionResult` |
| `src/state/context.ts` | Shared context/hook, separated to preserve Fast Refresh |
| `src/state/store.tsx` | Shared reports/draft/media/import session, save/update/reset; replace persistence calls when a backend exists |
| `src/adapters/mock.ts` | 44 synthetic metro records, illustrative agencies, versioned device storage and legacy migration |
| `src/services/detectionService.ts` | Mock photo/video adapter, JSON parsing, strict normalization; add agreed HTTP adapter here |
| `src/services/reportsService.ts` | List/get/save/reset/update reports; connect actual report endpoints here |
| `src/services/queueService.ts` | Active/all/history filtering, deterministic score ordering |
| `src/services/priorityService.ts` | Explainable triage calculation; confidence is never an input |
| `src/services/agencyService.ts` | Agency list/channel and unknown/unverified suggestion; integrate verified jurisdiction lookup here |
| `src/services/submissionService.ts` | Local prepare/submit adapter; connect official submission only after a real integration is agreed |
| `tests/services.test.mjs` | Focused Node tests using Vite's existing TypeScript loader, no new framework |

## Demo reports and persistence

44 deterministic approximate roadway coordinates span Indianapolis and Fishers. They are illustrative, not surveyed positions or official complaints. Labels explicitly say Approximate Demo Location. Evidence is an illustration (`public/sample-road.svg`), not a scene photograph. Agency routing is unverified and never inferred as INDOT ownership from a street name.

`pothole-patrol-v2` stores `{version:2, demo:[...], personal:[...]}` separately. First load migrates `pothole-patrol-v1`: replaces old `source:demo` records, preserves local/imported records, maps obsolete agency IDs to unknown, and leaves the legacy key intact as a backup. Reset replaces synthetic records/edits while preserving personal reports. Persisted temporary `blob:` URLs are stripped; uploaded media is session-only. HTTPS imported image URLs persist but can expire. Corrupt storage surfaces a load error; it is not silently overwritten. Do not clear all browser storage as an upgrade strategy.

Reports created from real-source imports have `source:imported`, retain the normalized detection including session, GPS accuracy and confidence, and start `lifecycle:locally_prepared`, `status:Open`. Saving a demo candidate creates `source:local`, rather than pretending to be imported inference.

`status` (`Open`, `Acknowledged`, `Fixed`) remains backward compatible. All dashboard status edits are local simulations. `Fixed` represents local resolved/history status, not independently verified repair. The optional separate lifecycle field can represent locally prepared, officially submitted, agency resolved, or repair verified; a detection candidate is not yet a report. No current UI action asserts official submission or repair verification.

## Browser photo/video workflow

1. Choose Photo or Video, then camera/upload controls. Browser video recording is available when getUserMedia/MediaRecorder and permissions permit. Device capture/upload remains a fallback.
2. Preview/remove/replace media. New media clears the prior analysis selection.
3. Choose Preview sample detection results: one photo candidate or three video candidates, explicitly marked demo; no inference or artificial progress animation runs.
4. Select one candidate. Review human-assessed severity (Medium default, not a model estimate), description, agency, hazard, and location. A sample duplicate is explicitly illustrative; real duplicate lookup is unavailable.
5. Enter a location description and numeric WGS84 coordinates, or choose coordinates on the map. Confirm location/severity with the required checkbox. Missing coordinates stay blank; no random address is assigned. Imported GPS is approximate and editable; original accuracy remains with detection metadata.
6. Review and save locally. Report appears immediately in shared map and active queue. Review another candidate returns to the same session. Already-saved source/session/detection IDs cannot be selected again in the candidate list. Different video frames are not automatically grouped; human review must avoid repeated physical issues.

Photo limit: 20 MB. Video: 150 MB. Recording needs HTTPS or localhost and device permission. Browser/iPhone codecs and permissions vary. Camera recording is not detection. Blob media is not retained across reloads; imported sessions/drafts are in memory until saved.

## JSON import contract (implemented)

Use Report Road Damage → Import Detection Results → Choose JSON file. Example: `examples/detection-results.json`. **That file is fictional contract test data with source `ios_coreml` to exercise the adapter; it is not actual inference output.** Replace it with real exported results for a model demonstration.

```json
{
  "schemaVersion": 1,
  "source": "ios_coreml",
  "sessionId": "scan-001",
  "detections": [{
    "id": "scan-001-frame-2400-box-0",
    "className": "pothole",
    "confidence": 0.87,
    "capturedAt": "2026-11-07T12:15:00-05:00",
    "frameTimestampMs": 2400,
    "boundingBox": {"x": 0.31, "y": 0.54, "width": 0.22, "height": 0.17},
    "location": null,
    "imageUrl": null
  }]
}
```

- Required envelope: `schemaVersion:1`, source (`ios_coreml`, `desktop`, `backend`, `demo`), `detections` array. Optional nonempty string `sessionId`.
- Required record: unique nonempty string `id`, recognized `className`, ISO observation `capturedAt` with timezone. Empty detection arrays are valid.
- Optional/null: confidence (number 0–1), boundingBox, frameTimestampMs (nonnegative elapsed milliseconds, not epoch time), location, imageUrl. Missing confidence stays unavailable.
- Box uses **normalized top-left origin** x/y and width/height in the oriented, uncropped evidence image, all within [0,1], positive dimensions and edges within the image. Pixel or center-based coordinates must be converted before export. Coordinates are not camera GPS.
- Location: `{latitude,longitude,accuracyMeters?}` in WGS84 decimal degrees (latitude −90..90, longitude −180..180); accuracy is a nonnegative radius in meters. A phone location is approximate observation metadata, not the pothole's exact coordinate. Do not set zero as a placeholder.
- imageUrl: absolute HTTPS URL to the actual matching image/frame, or null. Do not use a path from the phone, executable URLs, or unrelated sample footage. Imported URLs load when displayed and should point to approved evidence storage.
- Source determines demo labeling. Fields normalize into `DetectionResult` (`id` → `detectionId`; source/session copied from envelope); unavailable severity/GPS/depth are never manufactured. Unknown extra fields are ignored. Invalid records reject the entire file with an error; no partial reports are created. Limit: 5 MB / 1,000 candidates.
- UI shows class, confidence, frame time, optional image, GPS/accuracy state, and review action. It deliberately does not overlay boxes until matching evidence orientation/frame integrity is established.

## iOS teammate: export from the existing callback

Implement the export in the native project on your own branch; this frontend change does not edit native files.

1. Attach an exporter to the existing YOLOView `onDetection` callback (or `YOLOViewDelegate.yoloView(_:didReceiveResult:)`). Preserve existing callbacks/UI behavior; compose callbacks rather than overwriting someone else's consumer.
2. For each selected result, iterate `result.boxes`. Export `box.cls` as className and `Double(box.conf)` as confidence. Metadata confirms the four class labels. Validate against the contract above.
3. Export `box.xywhn.minX`, `.minY`, `.width`, `.height` to the normalized box. In the inspected Vision path the library has already converted the vertical origin. Never use the aspect-fill screen overlay rectangle, and verify orientation against the exported original frame. Clamp/clip tiny edge rounding safely or omit invalid boxes.
4. Generate a stable session ID and unique record ID. Add capture time from the capture session/device clock with timezone, and frameTimestampMs from elapsed recording time. `YOLOResult.speed` is inference duration, **not** the video frame timestamp.
5. GPS is not part of Box or YOLOResult: add independently captured, permissioned location/accuracy metadata if available; otherwise null. Severity/depth are not detector outputs.
6. Optionally export a matching original frame to approved evidence storage and include its HTTPS URL. `originalImage` is optional and must be explicitly enabled/captured; annotatedImage may already have drawn boxes. Do not assume either is present.
7. Throttle/select useful observations before export. The frontend lists candidates and guards repeat imports by exact source/session/id, but does not track objects or deduplicate adjacent frames. Keep a manageable file under the limits above.
8. Serialize with JSONEncoder using schemaVersion 1 and share the `.json` file. Import it in the web frontend, select one physical issue, confirm location/severity, and save locally. This is a temporary file bridge, not an iOS-to-web live service or a city submission.

For desktop, read `model.names[int(box.cls[0])]` and `float(box.conf[0])`; convert pixel `box.xyxy[0]` using frame width W and height H: x=x1/W, y=y1/H, width=(x2−x1)/W, height=(y2−y1)/H. Add independent timestamps/location, source desktop, and the same envelope. The current script only draws detections; it does not yet export this contract.

## Future backend contract (PROPOSED, not implemented)

`.env.example` reserves `VITE_API_BASE_URL`. Merely setting it does not enable HTTP requests: there are no agreed endpoints yet. All current analysis stays mock or JSON import. After agreement, implement a configured adapter within services, pass real responses through `normalizeDetections`, and show errors rather than silently substituting mock results for failed inference.

Proposed `POST /v1/detection-sessions` multipart request:

```text
media: image/jpeg or supported video file
metadata: {"clientSessionId":"scan-001","mediaType":"video","capturedAt":"2026-11-07T17:15:00Z"}
```

Proposed successful response: the implemented JSON envelope above, with source backend and optional real evidence URLs/location metadata. A future asynchronous API must agree job IDs, polling, cancellation and error semantics separately; the current frontend has no poller.

Proposed reviewed-report request `POST /v1/reports`:

```json
{"clientReportId":"LOCAL-uuid","detectionRef":{"source":"ios_coreml","sessionId":"scan-001","id":"scan-001-frame-2400-box-0"},"location":{"latitude":39.957,"longitude":-86.0145},"locationConfirmed":true,"address":"User-confirmed approximate intersection","damageType":"pothole","severity":"Medium","description":"User-reviewed damage","agencyId":"unknown","safetyHazard":false}
```

Proposed response: `{ "id":"report-server-001", "workflowState":"locally_prepared", "status":"Open", "officialSubmission":null, "updatedAt":"2026-11-07T17:20:00Z" }`. Saving to a backend alone does not imply official submission. Proposed `GET /v1/reports`, `GET /v1/reports/:id`, `PATCH /v1/reports/:id` should return shared normalized report fields; PATCH body could be `{ "status":"Acknowledged", "severity":"High", "expectedUpdatedAt":"..." }`. Agree authorization, concurrency, pagination, evidence retention, jurisdiction verification, and actual official-status provenance before wiring these up. Do not expose a submission-success label until an actual agency integration returns a verified reference.

Use `reportsService` and `updateReport` for shared report mutations; `submissionService` currently returns saved-locally only. Persist only validated reviewed data; future synchronization must distinguish agency closure from repair verification.

## Queue and metrics

Active includes Open/Acknowledged, excludes Fixed, default score descending with ID tie-break. All Reports and Fixed / History retain resolved reports. Search, severity, status, agency, observation and newest sort all operate on shared state.

Suggested Triage Score max 95: severity 10/25/40 + observations min(20,(count−1)×5) + hazard 0/20 + age min(15,whole elapsed days). It is a human-review suggestion, never municipal authority. An explicit clock can be supplied for deterministic tests. High Priority counts active scores ≥70. New Detections counts reviewed real-source imported reports captured within the preceding 7 days; unreviewed candidates and demo reports do not contribute. Total Observations includes all statuses.

## Validation and remaining work

Run from frontend: `npm run dev`, `npm run build`, `npm run lint`, `npm test`. Tests cover active/history queue, metro seed constraints, old-data migration, separate-source persistence/reset, normalized optional fields, invalid JSON/records, limits, and explainable scoring.

Manual browser checks should include Resident/Official switch, region recentering, marker detail, search/filter/sort, local severity/status edit, photo/video upload and remove, sample output, valid/invalid import, no detections, missing GPS, local save, reload, and 390px layout. Real hardware camera permissions/codecs still need device testing. Tile loading requires Internet; tile failures show a warning with markers retained. Integration work remaining: native/desktop JSON exporter, matching evidence transport, agreed backend adapter, actual jurisdiction data, duplicate tracking, official submission/status sync, and independent repair verification.


### Verification recorded for this implementation

- Production TypeScript/Vite build passed; lint passed with no warnings; all 10 service tests passed.
- Vite development server started successfully. Browser exercised resident/official navigation, explicit region movement, selected marker summary/detail drawer, observation sorting, active/history behavior, JSON import with two candidates, empty GPS fields, confirmed local save, shared severity/status edits, reload persistence, and safe demo reset preserving the imported QA report.
- Uploaded a PNG through the browser chooser, verified its preview, loaded explicitly labeled photo sample results, removed/replaced media, and checked video upload/record controls remain available.
- Tested a 390px viewport (375px content area with scrollbar): map, queue, analysis/form, and review pages had no horizontal page overflow after the form grid fix. Desktop map and table were inspected too. Region filters no longer carry invisibly into the queue when changing workspace routes.
- Browser camera access/recording and actual supported video playback were not exercised on iPhone hardware. These still require a device permission/codec test. Invalid/empty JSON and migration/reset edge cases are covered by automated service tests.
