# Pothole Patrol native iOS handoff

This is a native SwiftUI/UIKit iPhone app in the existing `YOLOiOSApp` target, minimum iOS 16. It uses MapKit, Core Location, the existing Ultralytics SDK, and the checked-in **pothole-yolo11n.mlpackage**. No React, WebView shell, new backend, or replacement inference implementation was added.

## Location of this work

- Feature branch: `native-pothole-patrol`
- Base: `origin/main` at `45ee2f4`
- Backend contract inspected: `origin/backend-docs:backend.md` at `dadedb98eafe9865676750d57983ad5a1082961e`
- Windows worktree: `C:\Users\aksha\Desktop\PotholePatrol\.worktrees\native-pothole-patrol`
- Project: `ios/YOLOiOSApp/YOLOiOSApp.xcodeproj`
- Scheme/target: `YOLOiOSApp`

The previous frontend checkout remains on its original branch. This work is **local and uncommitted**. No push/merge/PR was made. Another machine cloning GitHub will not see these changes until the team authorizes publishing the branch or transfers the changed files. Do not copy the Windows worktree's `.git` pointer to a Mac; transfer the source changes into a valid clone/worktree.

## Files and ownership

| File under `YOLOiOSApp/` | Responsibility |
| --- | --- |
| `SceneDelegate.swift` | UIHostingController root; RecordViewController runs Live Scan's YOLOView camera, tracker, area estimate and sliders |
| `AppDelegate.swift` | Native scene startup; `OrientationLock` keeps the app in portrait except Live Scan; external display uses ordinary mirroring to avoid the old dedicated screen creating another camera |
| `Patrol/PotholePatrolRootView.swift` | Scan / Map / My Reports / More shell, HTTPS Settings, permission state, shared badges and evidence views |
| `Patrol/LiveScannerView.swift` | Live Scan: full-screen presentation, camera authorization, keeping the screen awake |
| `Patrol/PhotoReportView.swift` | Report a Photo: stationary confirmation, plain iOS camera with no detection, capture location |
| `Patrol/DetectionReviewView.swift` | Still evidence review, original timestamp, explicit GPS/manual-map correction, upload/retry/save/discard |
| `Patrol/CitizenViews.swift` | Native public MapKit map, public detail, local-ID My Reports, modular pending-government-report notice |
| `Patrol/AdminViews.swift` | Secure sign-in, ranked operations queue, history, agency filter, map, read-only unassigned observations, confirmed status updates |
| `Patrol/PotholeModels.swift` | Documented snake_case DTOs with nullable fields and backend priority breakdown |
| `Patrol/PotholeAPI.swift` | HTTPS-only configuration, ngrok header, multipart JPEG request, exact routes, typed decoding/errors, no redirect forwarding |
| `Patrol/LocalServices.swift` | Core Location, stable random device ID, Keychain credentials, protected single pending-photo file |
| `Patrol/PatrolStore.swift` | Citizen shared data/upload and a separately authenticated administrator session |

Nine new app Swift files are explicitly in the Xcode app group and PBXSourcesBuildPhase. `Info.plist` has the Pothole Patrol name, camera/location purpose strings, and portrait iPhone orientation. Main.storyboard root declarations were removed so the generic controller does not initialize an extra camera. LaunchScreen remains. The generic Settings.bundle is no longer copied into the native app; settings live in More. The build phase that downloaded seven unused YOLO26 models was removed from the app target; the selected YOLO11n package is already in Models/Detect. SDK sources, model weights/packages, package version, signing identity, bundle ID, and build number were not changed. The existing icon is retained.

## Open and run on a Mac

1. Obtain this source change in a valid clone/worktree on branch `native-pothole-patrol`. Keep `ios/Package.swift` and `ios/Sources` beside `ios/YOLOiOSApp`; Xcode uses that local Swift package.
2. Open `ios/YOLOiOSApp/YOLOiOSApp.xcodeproj` in a current Xcode with an iOS 16-or-newer SDK (the SDK's newer optional APIs may require a recent Xcode).
3. Select scheme **YOLOiOSApp**. Under Signing & Capabilities select your own team. If necessary, choose an available personal development bundle identifier locally. Do not commit a teammate's signing change accidentally.
4. Confirm **Models** is a folder resource and contains `Models/Detect/pothole-yolo11n.mlpackage`, including its model and weights. This exact package is loaded using the original `setModel(modelPathOrName:task:completion:)` path. `best.mlpackage` remains a reference, not a fallback silently chosen by this app.
5. Build for an available simulator for UI/network checks. Live inference and photo capture require a physical iPhone. Connect/unlock the phone, enable Developer Mode if required, select it as destination, and Run.
6. In **More → Backend connection**, enter the current HTTPS base URL provided by Sanyam and save it. The temporary ngrok address is intentionally not bundled or committed. Tap **Check connection**. Every API request sets `ngrok-skip-browser-warning: true`.
7. The Scan tab has two modes:
   - **Live Scan:** set the phone height, mount the phone, and press Record before driving. Boxes and estimated area show on screen. Nothing is saved or sent.
   - **Report a Photo:** while safely stationary, confirm the toggle, take a photo, verify it, confirm/correct coordinates, then Confirm & Upload.
8. Open Map or My Reports. Use **Show All Reports** if the server's records lie outside Indianapolis/Fishers. No synthetic metro observations are inserted.
9. **More → Administrator Sign In**: enter the server passcode on the phone. Do not put it in project files or environment examples. The app verifies it with the server and stores only the returned token in Keychain. A saved token is revalidated using the protected queue before showing operations.

Optional simulator build from the repository root:

```sh
xcodebuild -project ios/YOLOiOSApp/YOLOiOSApp.xcodeproj \
  -scheme YOLOiOSApp -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Run `xcodebuild -showdestinations` with the same project/scheme for an explicit simulator/device destination. If SwiftPM reports missing **SDK test** resources, `bash ios/scripts/download-models.sh` is the existing SDK helper; it downloads test/reference models and must not replace the selected YOLO11n. Do not build the SDK test suite with `swift test` on Windows; UIKit is required.

## Actual camera behavior and evidence limitations

**Live Scan**

- YOLOView owns AVFoundation and Core ML, and the app creates no second capture session while Live Scan is open.
- `DetectionTracker` confirms a pothole across frames, and `GroundPlaneMeasurer` estimates its area. See the repository README.
- It's the only landscape screen, for a dashboard mount. It has no stationary check or speed stop, so it must be started before driving. Never operate a phone while driving.
- Closing it stops the camera, and going to the background stops detection until Record is pressed again. The screen stays awake while it's open.
- No video file is recorded, and nothing is saved or sent.

**Report a Photo**

- Uses `UIImagePickerController`, so the model doesn't run and the photo has no boxes on it.
- A stationary confirmation is required, and taking a photo is blocked when recent GPS reports a speed above 2 m/s. This is a limited safety aid, not a reliable driving detector, because poor or absent speed data can't prove someone is stationary.
- The app asks for a fresh location when the camera opens. If the photo takes more than about 15 seconds, the location stays empty and the resident sets it on the review screen.
- Capture time is recorded when the photo is returned.
- Photos are resized to at most 1920 points/pixels and compressed under 10 MiB, which also avoids retaining photo-library metadata. The backend additionally strips EXIF.

## Location, pending observations, and privacy

A fresh capture GPS is accepted only with valid horizontal accuracy at most 20 m and a timestamp within 15 s of the shutter request. Otherwise coordinates remain absent. The resident must confirm the location before upload and can enter coordinates or explicitly select the map center. No default map center becomes an observation coordinate automatically. Later GPS is an explicit manual correction, not silently assigned as the location of an earlier photo. This iteration has no gallery-import flow.

Location updates run while scanning, or as explicit one-shot requests for review/map centering. No background location mode, journey log, or continuous coordinate history is stored. The device ID is a random UUID in UserDefaults, stable across launches, not a hardware fingerprint.

Only one pending captured observation is retained. It includes its JPEG, original shutter time, optional capture accuracy, user-confirmed coordinates, and original attempted backend URL. Its Application Support file is atomically written with complete file protection and excluded from backups. A failed upload leaves the photo available in Scan/My Reports. Retrying keeps the timestamp and device ID. No automatic upload loop exists. A changed backend cannot silently receive a retry belonging to the old server. Review/discard the pending photo before capturing another.

After success, only the returned pothole ID is retained for My Reports, scoped to the backend URL. An original capture UUID receipt prevents a leftover cleanup file from being offered again after restart. Successful media is deleted; Settings also has Delete saved capture. No resident contact information is collected. Report IDs are fetched individually; 404 IDs are removed, while network errors preserve IDs.

## Backend endpoint integration

| Endpoint | Native integration |
| --- | --- |
| `GET /health` | Settings connectivity check. The user-supplied live URL returned **HTTP 200, {"status":"ok"}** during Windows implementation. No other live API action was performed. |
| `POST /detections` | One explicitly confirmed multipart request: photo JPEG, lat, lng, captured_at, device_id. New/merged response and actual returned ID shown. Not end-to-end exercised from a phone yet. |
| `GET /potholes` | Public map, admin map/history/unassigned section; up to documented maximum 1,000 records. No push/pagination contract is invented. |
| `GET /potholes/{id}` | Public detail and My Reports current state. |
| `GET /agencies` | Backend-provided administrator agency filter. |
| `POST /officials/verify` | SecureField passcode; requires verified:true and a token, then a successful protected queue request before opening operations. |
| `GET /queue` | Official token required. Backend order and backend score/breakdown; fixed entries filtered out defensively. |
| `PATCH /potholes/{id}/status` | Official token required; lower-case status; fixed confirmation; displayed status changes only after server success, followed by queue refresh. |
| `POST /potholes/{id}/send` | Existing contract represented only in the service/DTO layer. **No citizen UI calls it. Government handoff is disabled pending updated requirements.** |

DTOs follow the backend's `.convertFromSnakeCase` names (`photoUrl`, `agencyId`, etc.) and UTC ISO-8601 dates without fractions. Public requests have no official token. Protected requests add only `X-Official-Token`. URLSession uses ephemeral transport and rejects redirects to avoid forwarding credentials or photo bodies. No ATS bypass is added. HTTP errors preserve their status; wrong-passcode, rate-limit, unavailable authentication, validation, and connectivity failures show actionable errors.

## Administrator authority and status

Citizen views contain no severity, priority score, staff rankings, or status controls. AdminSession is separate and its authentication state is private-set. No predefined passcode/token or local-password comparison exists. Keychain is scoped by server URL, uses WhenUnlockedThisDeviceOnly accessibility, and never stores the passcode. Logout/401 deletes the credential and protected data; offline token restoration does not open the dashboard. Authentication remains server-authorized for every queue/status call.

The active queue shows backend-ranked assigned work; no React scoring is reused. History retains fixed assigned reports. Unassigned / Needs Jurisdiction Review is separately populated from public records and is read-only, without a claimed maintenance rank. Fixed and other status changes remain disabled for those unassigned detail views, per the read-only requirement. Sanyam must clarify authorization for assigning/updating unknown-owner observations in the next contract if that is needed for the demo.

After a successful patch, local shared state uses the returned record, the authenticated queue is refreshed, and citizen data can refresh from the server. A failed patch never simulates success. Agency filtering is preserved during re-ranking. A fixed status is not labeled as independently verified repair.

## Updated government and jurisdiction decisions

SeeClickFix handoff has been discontinued. The app does not open legacy agency links, autofill forms, collect agency passwords, offer "I submitted it", or call /send from the UI. `GovernmentReportingNotice` is the small replacement point when an updated contract exists. Sanyam should confirm the replacement reporting workflow before enabling it.

Indianapolis/Fishers is the default map area, but ownership expansion to Marion/Hamilton County is **not assumed**. Unknown/private owner fields stay nullable. Unverified metro observations remain visible on the public map and in the staff unassigned view; no DPW/Fishers/INDOT ownership is invented. The current backend may exclude these observations from `/queue`, even after upload.

For Sanyam: expand/confirm Marion and Hamilton County ownership coverage and agency IDs; specify the new government-reporting contract; clarify whether unknown-owner observations may receive protected status updates; and confirm real-device HTTPS availability. These changes belong to the backend, not a client-side ownership heuristic.

## Validation performed and still required

**Performed on Windows:** fetched references; inspected complete backend guide, model/camera APIs, project resources; created isolated worktree; checked target references/object IDs, permission plist, root startup and unchanged SDK/model files; parsed all new/changed Swift plus the contract harness with tree-sitter (syntax only); checked Git whitespace. Read-only `/health` succeeded. No real detections, government submissions, authentication attempts, or status mutations were sent to the live backend.

Static checks can be repeated from any host with Python:

```sh
python ios/YOLOiOSApp/Validation/validate_project.py
```

For optional Swift syntax parsing, install `tree-sitter` and `tree-sitter-swift` into a temporary directory and supply `--swift-parser-path /absolute/path/to/that/directory`. This does **not** compile Swift or resolve Apple SDK APIs.

A small **unexecuted** Foundation URLProtocol harness covers DTO null/date decoding, HTTPS validation, token separation, login/queue/status request contracts, multipart fields/timestamp/device ID, and HTTP errors. On a Mac, from repo root:

```sh
swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  ios/YOLOiOSApp/YOLOiOSApp/Patrol/PotholeModels.swift \
  ios/YOLOiOSApp/YOLOiOSApp/Patrol/PotholeAPI.swift \
  ios/YOLOiOSApp/Validation/ContractChecks.swift \
  -o /tmp/pothole-patrol-contract-checks
/tmp/pothole-patrol-contract-checks
```

Its synthetic URLProtocol intercepts every request; it never contacts the live backend. It is deliberately outside the app target and contains no real administrator credential.

**Not verified here:** Xcode type checking/linking, SwiftUI layout on simulator/device, signing, Keychain persistence, actual camera permissions/interruptions, live inference, matching still rendering, GPS accuracy/speed behavior, photo disk protection/recovery, real JPEG upload/merge, live admin authentication/401 transitions/status edits, and MapKit rendering. No successful iOS build or device test is claimed. Camera is not testable in the simulator. iOS 16 deprecated Map APIs are retained for compatibility; a later UI modernization is optional.

### Mac/iPhone acceptance pass

1. Build simulator and physical-device destinations. Resolve compiler/API/availability diagnostics before calling this a tested app.
2. Exercise camera/location denied, no rear camera (simulator), model loading/failure, pause/resume/backgrounding, no detection, three-frame candidate, still capture/confirmation, and map/manual GPS correction. Confirm no second camera appears with an external display attached.
3. With Sanyam's current URL, check health. Send one **real, consented** pothole capture while stationary; verify actual JPEG, capture time, backend new/merge response, returned ID, public map and My Reports. Do not flood synthetic uploads.
4. Turn off connectivity after capture; retry/relaunch and confirm the original photo/time survive. Verify successful cleanup and explicit discard. Confirm changing backend cannot replay a queued observation to another server.
5. Enter the passcode only in the app. Test incorrect passcode/rate-limit UI with Sanyam's coordination, protected queue, agency filters, logout, invalidated-token 401, and offline saved-token restore. Citizens must never see staff content.
6. Coordinate one real backend status edit with the team. Confirm Fixed removes assigned work from Active and remains in History; citizen refresh sees it. Unknown-owner records must remain visible in the read-only unassigned area rather than being falsely ranked or assigned.
7. Confirm the pending-government-report notice and absence of SeeClickFix/automatic submission. Do not submit test reports to an agency.
