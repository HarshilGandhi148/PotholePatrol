# PotholePatrol

Pothole reporting that sends each report to whoever actually owns the road
(INDOT, the city, the county, or nobody for private roads), in that agency's
format. Built at the Indy Init hackathon (deadline 5:00 PM, Nov 7, 2026).

**Read `docs/PLAN.md` first.** It has the scope, decisions, open questions and build order.

## Repo layout

- `backend/`: Python (FastAPI). Run all backend commands from this folder.
  - `app/main.py`: the API routes; contract in `docs/API.md`
  - `app/owner.py`: `resolve_owner`, who owns the road
  - `app/map_data.py`: loads road and boundary GeoJSON
  - `app/agencies.json`: one entry per agency; form fields are placeholders
  - `scripts/fetch_map_data.py`: downloads real map data into `backend/data/`
  - `tests/`: pytest; `tests/fixtures/mini_city` is a synthetic offline map
- `ios/`: the iOS app (UIKit, Xcode), built by the team. It holds both the resident and
  the officials views, chosen on the first screen.

## Commands

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python scripts/fetch_map_data.py   # real map data (needs internet)
python -m pytest -q
```

## Rules

- Work function by function. For each one: explain in plain English what it does,
  write it, write tests, run the tests, commit. The team wants to understand each piece.
- Every new function gets tests. Keep the test suite fast and offline by default;
  tests that need downloaded data must skip cleanly when `backend/data/` is missing.
- **The server never sends reports to agencies.** The app opens the agency's real page
  in WKWebView and the resident taps the agency's own Submit.
- API responses use snake_case JSON, UTC ISO 8601 dates and full HTTPS image URLs.
- No subjective AI severity descriptions. Potholes are named by location
  ("Pothole on X near Y"). Priority comes from the number of distinct reporters.
- Secrets go in `backend/.env` (gitignored). Never commit keys.
- Strip EXIF from photos before storing them. Never store vehicle routes.
- UI work: minimal, mobile first, designed with care.
