# PotholePatrol backend

Python. Run everything from this `backend/` folder.

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python scripts/fetch_map_data.py   # downloads real map data into data/ (needs internet)
cp .env.example .env               # then set your own values
python -m pytest -q                # runs the tests
uvicorn app.main:app --port 8000   # starts the API
```

The iOS app needs HTTPS. In a second terminal, `ngrok http 8000` gives you a public HTTPS URL.
Photo URLs use `PUBLIC_BASE_URL`, or the address the phone called if that is empty.

The API contract for the iOS app is in `docs/API.md`.

## Add an agency

Add one entry to `app/agencies.json`. Set `autofill_ready` to true only after its form
`selector` values have been tested in WKWebView. Nothing else needs to change.

## Privacy and safety

- The server never contacts an agency. A test fails if `app/` imports an HTTP or email client.
- Photos are re-saved with no EXIF.
- `detections` stores a hash that differs per device and pothole, plus the date. No location, device id or time of day.

## Function 1: `resolve_owner(lat, lng, data)` (app/owner.py)

Works out who has to fix the road at a GPS point, in this order:

1. **State road** (interstate, US route, Indiana state route): INDOT, even inside a city.
2. **Private road, driveway or parking lot:** no public agency.
3. **Inside a city or town boundary:** that city or town.
4. **Otherwise:** the county.

Returns the agency, a plain-English reason for the resident, a confidence level
(lower when the pin is far from the road or at an intersection of roads with
different owners) and the road name.

Data sources:
- Roads: OpenStreetMap, via the Overpass API (`ref` tags like `US 231`, `I 65`, `IN 26`)
- City, town and county boundaries: US Census TIGER/Line 2024

Tests in `tests/test_owner.py` use a small synthetic map in `tests/fixtures/mini_city`
so they run offline.
