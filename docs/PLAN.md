# PotholePatrol: build plan and handoff

Last updated: Sat Nov 7, 2026, 12:15 PM ET (Indy Init hackathon day).

## 1. The hackathon

- **Event:** Indy Init, Launch Fishers. Building runs to the deadline: **Devpost submission closes at 5:00 PM sharp**.
- **Rules:** public GitHub repo, built during the event.
- **Categories:** Software Factory, Community Impact, Wildcard.
- **Software Factory is about the harness behind the app:** tests, CI, standards, security, a pipeline that could run again next month. Judges come to the table science-fair style and ask how it was built. Show tests and CI, not just a demo.

## 2. The problem (from research)

- **Finding potholes is not the bottleneck.** Lafayette closes pothole reports in about 5 days (median, 2026). Indianapolis filled 5,600+ potholes in the first week of 2026 against only 469 requests, so crews find most potholes themselves.
- **Money is the real constraint.** 31% of Indiana city and town roads are in poor condition, and local governments are short about $987M a year just to keep roads from getting worse (Purdue LTAP 2024 Local Road and Bridge Report).
- **Residents don't know who owns the road or which form to use.** Every city, county and INDOT has its own channel. Real Indiana cases: 42nd St on the Indianapolis and Lawrence border (each city pointed at the other), a Morgan County road both the county and INDOT said the other owned, and a private street on Indy's south side the Request Indy app rejected.
- Lafayette pothole reports on SeeClickFix: 54 (2022), 72, 95, 132, 148 (2026, so far). Low volume, but nearly tripled.

**Our product:** a pothole gets detected or reported, the app works out who owns the road, and the report goes to the right agency in the right format. Officials get one ranked list of what to fix first.

## 3. Scope for today (decided)

Three agencies, in Indianapolis and Fishers. Tippecanoe County is out of scope.

| Agency | Owns | How it takes reports | Status |
|---|---|---|---|
| City of Indianapolis | City streets in Marion County, outside the excluded cities | Request Indy: https://request.indy.gov/ . Phone: 317-327-4622 (Mayor's Action Center). | Found; **get the exact fields** |
| City of Fishers | City streets | Fishers Connect, on SeeClickFix: https://seeclickfix.com/web_portal/26pMJzv8jeF89NAhJy6TgFXT/report/category/28527 . Guests allowed. Phone: 317-595-3111. | Autofill by label, testing on iPhone |
| INDOT | Interstates, US routes, Indiana state routes | Report a Concern: https://indot4u.511in.org/report . Has reCAPTCHA. Hazards: call 1-855-INDOT4U. Up to 15 business days to repair. | Found; **get the exact fields** |

Anything outside these three still shows who owns the road, so no dead ends. That includes Lawrence, Speedway, Beech Grove and Southport.

**The scaling story for judges:** city and county boundaries are statewide, and roads are one download per region. Adding an agency means adding one entry to `agencies.json`.

## 4. Decisions made

- **No AI severity description.** It's subjective. Each pothole is named by location instead: "Pothole on US 231 near Veterans Memorial Pkwy" (nearest road plus nearest cross street).
- **Priority = how many people it affects**, measured by the number of distinct detections or reporters. A pothole on a busy road gets more detections, and that is correct because it affects more people. The formula is simple math in one function.
- **Where the AI is:** (1) pothole detection in the phone app (already built by the team), (2) reading agency forms to build each agency's field map, and (3) writing the value for each form field. Optional: a quick "is this actually a pothole?" check on uploaded photos.
- **The server never sends anything to an agency.** The backend returns a *send plan*, and the app follows it:
  - **Request Indy, Fishers Connect, INDOT:** the app opens the real page in WKWebView, the resident checks it and taps the agency's own Submit. Form fields are placeholders until the WKWebView tests are in; until then the app offers text to copy.
  - **Email agency:** open a prefilled email with the photo attached.
  - **Phone:** a call script plus tap to call.
- **Officials' view is in the same iOS app,** chosen on the first screen and unlocked with one shared passcode through `POST /officials/verify`. Real accounts wait for MVP 2. It stays minimal: priority list plus map plus "Mark fixed". Each row shows road name, report count, a small photo and the button. Status changes flow back to residents.
- **Moved to MVP 2:** report detail page, "getting worse" tracking, insights (repeat repair hotspots, misrouted reports, response times by neighborhood).
- **Demo data:** real detections only. Nothing is labelled as real unless it is.
- **UI:** minimal and designed with care, not generic vibe-coded. Mobile first.
- **Privacy:** read photo GPS, then strip EXIF before storing. Store pothole locations, never vehicle routes. Face and plate blur is a stretch goal.
- **Location:** if the app takes the photo or video itself, use live GPS at capture time. For gallery photos, read EXIF GPS and time in the app; never use the phone's current GPS for an old photo.

## 5. End-to-end flow

Phone app (team's existing detection app):
1. Record video while driving, logging GPS continuously.
2. The detection model finds a pothole.
3. Grab the best frame and the GPS at that moment.
4. Merge repeat frames of the same pothole into one detection.
5. POST one detection (photo, lat, lng, time, device id) to the backend.

Backend (this repo, `backend/`):
6. Optional: `is_pothole(photo)` check.
7. `find_duplicate(lat, lng)`: open pothole within about 25 m? If yes, add a +1 from this device.
8. `resolve_owner(lat, lng)`: INDOT, city, county or private. **Done.**
9. `get_channel(agency_id)`: look up the agency in `agencies.json`.
10. `priority_score(pothole)`: update the score.
11. `build_submission(pothole, agency, user_profile)`: produce the send plan.

Back on the phone:
12. Review and send (one tap, autofilled form, email, or call).

Officials:
13. See the ranked list and map, mark fixed, and residents see the update.

## 6. Open questions (decide or check early)

1. **Who sends the official report when detection is passive?** Decided: once enough different devices have seen a pothole, the API sets `ask_to_send` and one resident reports it. `SEND_THRESHOLD` defaults to 3; use 1 for the demo.
2. **Phone app tech:** decided. iOS, UIKit, Xcode. Where the detection code lives is still open; it isn't pushed to the repo yet.
3. **Database:** decided. SQLite. Hosting is still open.
4. **Request Indy, Fishers Connect and INDOT forms:** exact fields, whether a sign-in is needed, and whether each accepts a photo.

## 7. Backend build order

Each step: write the function, write tests, run `python -m pytest -q`, commit.

### Done
**1. `resolve_owner(lat, lng, data)`** in `app/owner.py`, with map loading in `app/map_data.py`.
- Order: state route (ref like I 65, US 231, IN 26, SR 25) goes to INDOT, then private road or parking lot, then inside a city or town boundary, then the county.
- Returns `agency_id` (`indot`, `city:indianapolis`, `city:fishers`), `agency_name`, `kind`, plain-English `reason`, `confidence` (lower when the pin is over 15 m from the road or at an intersection with a different owner), `road_name`.
- Map data: roads from OpenStreetMap via Overpass; city, town and county boundaries from Census TIGER 2024. Download with `python scripts/fetch_map_data.py` (needs internet).
- Offline tests on a synthetic map (`tests/fixtures/mini_city`).
- Route numbers come from the road's `ref` tag and OSM route relations; ramps inherit the route of the state road they touch. Census-designated places are not treated as cities.
- `tests/test_owner_real.py` has real golden points, checked against INDOT's route layer; it skips if `data/` is missing. Purdue campus streets are not locked in: who maintains them is unverified.

### Built (steps 2 to 11)
Everything below is built and tested. The contract for the app is in `docs/API.md`.

**2. `agencies.json` + `get_channel(agency_id)`**
- One entry per agency: `id`, `name`, `channel` (`webform` | `email` | `phone`), `url`, `phone`, `email`, `expected_response`, plus channel details:
  - Web form: `fields`, a list of `{key, label, selector, required, source}`, where `source` says where the value comes from (`road_name`, `cross_street`, `description`, `user.first_name`, `photo`, and so on).
- `get_channel` returns the entry, or a "contact only" fallback for agencies not in the file.
- Tests: every agency that `resolve_owner` can return in the MVP area exists in the file, and every web form field has a valid `source`.

**3. `name_pothole(lat, lng)`**: "Pothole on {road} near {cross street}". Uses the roads already loaded: the nearest road, then the nearest *other* named road within about 300 m.

**4. `build_submission(pothole, agency, user_profile)` returns a `SendPlan`**
- See the send plan in `docs/API.md`.
- The description is factual: location name, report count, first seen date. No severity opinions.
- Tests: one per channel type; required fields are never empty.

**5. `mark_sent`** records that a resident submitted, so nobody reports it twice. This replaced the SeeClickFix sender and status sync.

**6. `find_duplicate(lat, lng)` + `add_detection`**: cluster within about 25 m among open potholes; count distinct devices, so one person driving past 10 times counts once.

**7. `priority_score(pothole)`**: mainly distinct reporters; tie-breakers road class (arterial over residential) and days open. Show the breakdown so officials can trust it.

**8. Storage**: SQLite tables `potholes`, `detections`, `submissions`, `status_events`.

**9. FastAPI routes** (`app/main.py`)
- `POST /detections` (photo, lat, lng, captured_at, device_id) returns `{pothole_id, is_new, owner, name, priority, send_plan?}`
- `GET /potholes` (map, with filters: agency, status)
- `GET /queue?agency_id=` (officials' ranked list)
- `POST /potholes/{id}/send` (records that the resident submitted)
- `POST /officials/verify` (passcode for a token)
- `PATCH /potholes/{id}/status` (official marks acknowledged or fixed)
- `GET /agencies`

**10. Seed data**: dropped. There is no open Indianapolis data to import without a token, so the database starts empty.

**11. CI**: `.github/workflows/backend-tests.yml` runs pytest on every push (added).

## 8. Software Factory checklist

- [x] Unit and golden tests for the owner lookup
- [x] CI workflow running tests on push
- [x] Real-data golden tests (US 40 goes to INDOT, East Washington Street downtown to Indianapolis, 116th Street to Fishers)
- [x] Tests for agencies.json validity, send plans, dedupe and priority
- [x] The server can't send to agencies, with a test proving it
- [x] Secrets in `.env`, never committed (`.env` is gitignored)
- [x] EXIF stripped before storage, with a test
- [x] Structured logging on the API
- [x] README: how to run, how to add an agency

## 9. Time plan (deadline 5:00 PM)

| Time | Backend |
|---|---|
| 12:15 to 1:00 | Push function 1. Download real map data, add real golden tests. Check the Tippecanoe and INDOT forms, write agencies.json (step 2). |
| 1:00 to 2:00 | Naming, send plans, `mark_sent` (steps 3 to 5) |
| 2:00 to 3:00 | Dedupe, priority, SQLite, API routes (steps 6 to 9). Connect to the app. |
| 3:00 to 4:00 | Seed real Lafayette data, end-to-end demo run, fix bugs |
| 4:00 to 4:40 | Freeze features. README, Devpost write-up, rehearse the 30-second pitch |
| 4:40 to 5:00 | Submit on Devpost. Don't wait for the last minute. |

## 10. Demo script

1. A detection comes in on East Washington Street downtown: the City of Indianapolis owns it.
2. Another comes in farther east, on the same street, outside I-465: it's US 40 there, so it goes to INDOT.
3. The right agency's real page opens with the report ready. Stop before Submit.
4. A detection on 116th Street goes to Fishers.
5. Officials' view: sign in, see the ranked list, mark one fixed, and the resident's view updates.
6. Show the tests and CI run. Then the scaling story.

## 11. Sources

- Lafayette reporting: https://lafayette.in.gov/3537/Report-an-Issue
- INDOT4U: https://www.in.gov/indot/indot4u/
- Purdue LTAP 2024 Local Road and Bridge Report: https://www.purdue.edu/inltap/resources/2024-08-20-Indiana-Local-Road-and-Bridge-Report---FINAL.pdf
- Indy DPW first week of 2026: https://www.wrtv.com/news/local-news/indy-dpw-fills-more-than-5-000-potholes-in-first-week-of-2026-still-lots-of-work-to-go/
- Ownership confusion cases: https://www.wrtv.com/news/local-news/indianapolis/east-side/potholes-near-lawrence-border-frustrate-east-side-drivers , https://www.wrtv.com/news/call-6-investigators/fight-over-who-owns-500-foot-piece-of-morgan-co-road-leaves-potholes-unfilled-drivers-frustrated
- Indy Init: https://indyinit.com/hackathon
