"""API tests: the contract the iOS app depends on."""

import re

from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import PASSCODE, make_settings

ISO_8601 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SNAKE_CASE = re.compile(r"^[a-z][a-z0-9_]*$")


def _keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from _keys(item)


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_new_detection_returns_everything_the_app_needs(detect):
    body = detect().json()
    pothole = body["pothole"]
    assert body["is_new"] is True
    assert body["ask_to_send"] is True
    assert body["send_plan"]["method"] == "open_form"
    assert pothole["owner"]["agency_id"] == "city:indianapolis"
    assert pothole["title"].startswith("Pothole on Main Street")
    assert pothole["priority"]["reporters"] == 1


def test_json_keys_are_snake_case(detect):
    assert all(SNAKE_CASE.match(key) for key in _keys(detect().json()))


def test_dates_are_iso_8601_without_fractions(client, detect, official_headers):
    pothole = detect().json()["pothole"]
    fixed = client.patch(f"/potholes/{pothole['id']}/status", json={"status": "fixed"}, headers=official_headers).json()
    for value in (fixed["pothole"]["first_seen"], fixed["pothole"]["updated_at"], fixed["pothole"]["fixed_at"]):
        assert ISO_8601.match(value)


def test_captured_at_with_a_time_zone_is_converted_to_utc(detect):
    pothole = detect(captured_at="2026-11-07T10:00:00-05:00").json()["pothole"]
    assert pothole["first_seen"] == "2026-11-07T15:00:00Z"


def test_photo_url_is_full_https_and_loads(client, detect):
    url = detect().json()["pothole"]["photo_url"]
    assert url.startswith("https://api.test/photos/") and url.endswith(".jpg")
    assert client.get(url.removeprefix("https://api.test")).headers["content-type"] == "image/jpeg"


def test_photo_url_is_https_with_no_public_url_set(tmp_path, map_data, jpeg):
    settings = make_settings(tmp_path, public_base_url="")
    with TestClient(create_app(settings, map_data)) as client:
        response = client.post(
            "/detections",
            data={"lat": 40.4201, "lng": -86.88, "captured_at": "2026-11-07T15:00:00Z", "device_id": "device-0001"},
            files={"photo": ("p.jpg", jpeg, "image/jpeg")},
        )
    assert response.json()["pothole"]["photo_url"].startswith("https://")


def test_second_device_merges_and_raises_priority(detect):
    first = detect(device_id="device-0001").json()
    second = detect(device_id="device-0002", lng=-86.88005).json()
    assert second["is_new"] is False
    assert second["pothole_id"] == first["pothole_id"]
    assert second["pothole"]["report_count"] == 2
    assert second["pothole"]["priority"]["score"] > first["pothole"]["priority"]["score"]


def test_same_device_twice_counts_once(detect):
    detect(device_id="device-0001")
    assert detect(device_id="device-0001").json()["pothole"]["report_count"] == 1


def test_threshold_holds_back_the_send_plan(tmp_path, map_data, jpeg):
    settings = make_settings(tmp_path, send_threshold=2)
    with TestClient(create_app(settings, map_data)) as client:
        def post(device):
            return client.post(
                "/detections",
                data={"lat": 40.4201, "lng": -86.88, "captured_at": "2026-11-07T15:00:00Z", "device_id": device},
                files={"photo": ("p.jpg", jpeg, "image/jpeg")},
            ).json()

        first = post("device-0001")
        assert first["ask_to_send"] is False and first["send_plan"] is None
        assert post("device-0002")["ask_to_send"] is True


def test_private_road_never_asks_to_send(detect):
    body = detect(lat=40.390, lng=-86.8775).json()
    assert body["pothole"]["owner"]["kind"] == "private"
    assert body["ask_to_send"] is False and body["send_plan"] is None


def test_bad_input_is_rejected(client, detect, jpeg):
    assert detect(lat=95).status_code == 422
    assert detect(lat="nan").status_code == 422
    assert detect(device_id="x").status_code == 422
    assert detect(captured_at="2099-01-01T00:00:00Z").status_code == 422
    fake = client.post(
        "/detections",
        data={"lat": 40.42, "lng": -86.88, "captured_at": "2026-11-07T15:00:00Z", "device_id": "device-0001"},
        files={"photo": ("p.jpg", b"not an image", "image/jpeg")},
    )
    assert fake.status_code == 422


def test_oversized_photo_is_rejected(tmp_path, map_data, jpeg):
    settings = make_settings(tmp_path, max_photo_bytes=10)
    with TestClient(create_app(settings, map_data)) as client:
        response = client.post(
            "/detections",
            data={"lat": 40.42, "lng": -86.88, "captured_at": "2026-11-07T15:00:00Z", "device_id": "device-0001"},
            files={"photo": ("p.jpg", jpeg, "image/jpeg")},
        )
    assert response.status_code == 413


def test_list_filters_by_agency_and_status(client, detect):
    detect()
    assert len(client.get("/potholes").json()["potholes"]) == 1
    assert len(client.get("/potholes", params={"agency_id": "indot"}).json()["potholes"]) == 0
    assert len(client.get("/potholes", params={"status": "fixed"}).json()["potholes"]) == 0
    assert client.get("/potholes", params={"status": "nonsense"}).status_code == 422


def test_get_pothole_includes_the_send_plan(client, detect):
    pothole_id = detect().json()["pothole_id"]
    body = client.get(f"/potholes/{pothole_id}").json()
    assert body["send_plan"]["agency_id"] == "city:indianapolis"
    assert client.get("/potholes/missing").status_code == 404


def test_send_marks_it_once_and_stops_asking(client, detect):
    pothole_id = detect().json()["pothole_id"]
    first = client.post(f"/potholes/{pothole_id}/send", json={"method": "open_form"}).json()
    second = client.post(f"/potholes/{pothole_id}/send", json={"method": "open_form"}).json()
    assert first["already_sent"] is False and first["pothole"]["sent"] is True
    assert second["already_sent"] is True
    assert detect(device_id="device-0002").json()["ask_to_send"] is False


def test_send_on_private_road_is_refused(client, detect):
    pothole_id = detect(lat=40.390, lng=-86.8775).json()["pothole_id"]
    assert client.post(f"/potholes/{pothole_id}/send", json={"method": "open_form"}).status_code == 409


def test_agencies_lists_the_three_mvp_agencies(client):
    ids = {agency["id"] for agency in client.get("/agencies").json()["agencies"]}
    assert ids == {"indot", "city:indianapolis", "city:fishers"}


def test_verify_accepts_right_passcode_and_rejects_wrong(client):
    good = client.post("/officials/verify", json={"passcode": PASSCODE})
    assert good.status_code == 200
    assert good.json()["verified"] is True and good.json()["token"]
    assert client.post("/officials/verify", json={"passcode": "wrong"}).status_code == 401


def test_token_is_not_the_passcode(client):
    assert client.post("/officials/verify", json={"passcode": PASSCODE}).json()["token"] != PASSCODE


def test_verify_locks_after_repeated_guesses(client):
    for _ in range(10):
        client.post("/officials/verify", json={"passcode": "wrong"})
    assert client.post("/officials/verify", json={"passcode": PASSCODE}).status_code == 429


def test_verify_fails_closed_with_no_passcode_set(tmp_path, map_data):
    with TestClient(create_app(make_settings(tmp_path, official_passcode=""), map_data)) as client:
        assert client.post("/officials/verify", json={"passcode": ""}).status_code == 503


def test_official_routes_need_a_token(client, detect):
    pothole_id = detect().json()["pothole_id"]
    assert client.get("/queue").status_code == 401
    assert client.patch(f"/potholes/{pothole_id}/status", json={"status": "fixed"}).status_code == 401
    bad = {"X-Official-Token": "wrong"}
    assert client.patch(f"/potholes/{pothole_id}/status", json={"status": "fixed"}, headers=bad).status_code == 401


def test_queue_ranks_by_reporters(client, detect, official_headers):
    one = detect(lng=-86.8700, device_id="device-0001").json()["pothole_id"]
    two = detect(lng=-86.8800, device_id="device-0001").json()["pothole_id"]
    detect(lng=-86.8800, device_id="device-0002")
    ranked = [p["id"] for p in client.get("/queue", headers=official_headers).json()["potholes"]]
    assert ranked == [two, one]


def test_marking_fixed_leaves_the_queue_and_residents_see_it(client, detect, official_headers):
    pothole_id = detect().json()["pothole_id"]
    response = client.patch(f"/potholes/{pothole_id}/status", json={"status": "fixed"}, headers=official_headers)
    assert response.json()["pothole"]["status"] == "fixed"
    assert client.get("/queue", headers=official_headers).json()["potholes"] == []
    assert client.get(f"/potholes/{pothole_id}").json()["pothole"]["status"] == "fixed"


def test_detection_after_fix_creates_a_new_pothole(client, detect, official_headers):
    pothole_id = detect().json()["pothole_id"]
    client.patch(f"/potholes/{pothole_id}/status", json={"status": "fixed"}, headers=official_headers)
    assert detect(device_id="device-0002").json()["is_new"] is True


def test_bad_status_is_rejected(client, detect, official_headers):
    pothole_id = detect().json()["pothole_id"]
    response = client.patch(f"/potholes/{pothole_id}/status", json={"status": "gone"}, headers=official_headers)
    assert response.status_code == 422
