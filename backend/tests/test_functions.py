"""Unit tests for each backend function, using the offline synthetic map."""

import io
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from PIL import Image

from app.agencies import CHANNELS, FIELD_SOURCES, get_channel, load_agencies
from app.db import connect, init_db, iso
from app.detections import (
    add_detection,
    create_pothole,
    find_duplicate,
    hash_reporter,
    mark_sent,
    should_ask_to_send,
)
from app.naming import name_pothole
from app.officials import FailureLimiter, MAX_FAILURES, official_token, passcode_matches, token_matches
from app.owner import resolve_owner
from app.photos import BadPhoto, clean_photo
from app.priority import priority_score
from app.submission import build_submission

NOW = datetime(2026, 11, 7, 15, 0, tzinfo=timezone.utc)


@pytest.fixture
def conn(tmp_path):
    connection = connect(tmp_path / "unit.db")
    init_db(connection)
    yield connection
    connection.close()


def _insert(conn, data, pothole_id, lat=40.4201, lng=-86.8800, status="open"):
    create_pothole(
        conn, pothole_id, lat, lng, resolve_owner(lat, lng, data), name_pothole(lat, lng, data),
        "2026-11-07T15:00:00Z", status=status,
    )


# ---------- agencies ----------


@pytest.mark.parametrize("agency_id", ["indot", "city:indianapolis", "city:fishers"])
def test_every_mvp_agency_exists(agency_id):
    assert get_channel(agency_id)["channel"] != "contact_only"


def test_unknown_agency_falls_back_to_contact_only():
    agency = get_channel("city:battle-ground", "Town of Battle Ground")
    assert agency["channel"] == "contact_only"
    assert agency["name"] == "Town of Battle Ground"


def test_agency_file_is_valid():
    for agency in load_agencies():
        assert agency["channel"] in CHANNELS
        for field in agency["fields"]:
            assert field["source"] in FIELD_SOURCES or field["source"].startswith("user.")


def test_forms_are_only_ready_when_the_app_can_find_every_field():
    for agency in load_agencies():
        findable = all(field["selector"] or field.get("match_label") for field in agency["fields"])
        if agency["autofill_ready"]:
            assert findable


def test_fishers_opens_the_real_pothole_form():
    agency = get_channel("city:fishers")
    assert agency["url"].endswith("/report/category/28527")
    assert agency["autofill_ready"] is True


def test_fishers_plan_fills_each_step_and_leaves_submit_to_the_resident():
    plan = build_submission(_pothole(agency_id="city:fishers"))
    fields = {field["key"]: field for field in plan["fields"]}
    assert fields["location_search"]["step"] == 1
    assert fields["location_search"]["value"] == "40.42000, -86.88000"
    assert fields["summary"]["step"] == 2
    assert fields["summary"]["value"] == "Pothole on Main Street"
    assert fields["contact"]["value"] is None
    assert "Tap Submit yourself." in plan["instructions"]


def test_other_agencies_stay_on_copy_text():
    assert get_channel("indot")["autofill_ready"] is False
    assert get_channel("city:indianapolis")["autofill_ready"] is False


# ---------- naming ----------


def test_name_uses_road_and_cross_street(map_data):
    name = name_pothole(40.4200, -86.8990, map_data)
    assert name.title == "Pothole on Main Street near Sagamore Parkway"
    assert name.road_name == "Main Street"


def test_name_for_state_road_shows_the_route(map_data):
    assert name_pothole(40.400, -86.9000, map_data).road_name == "Sagamore Parkway (US 52)"


def test_name_with_no_road_nearby(map_data):
    assert name_pothole(40.380, -86.860, map_data).title == "Pothole on an unnamed road"


# ---------- send plans ----------


def _pothole(**overrides):
    return {
        "title": "Pothole on Main Street", "lat": 40.42, "lng": -86.88, "road_name": "Main Street",
        "cross_street": None, "report_count": 3, "first_seen": "2026-11-07T15:00:00Z",
        "photo_url": "https://api.test/photos/a.jpg", "agency_id": "city:indianapolis",
        "agency_name": "City of Indianapolis", **overrides,
    }


def test_city_plan_opens_the_city_page():
    plan = build_submission(_pothole())
    assert plan["method"] == "open_form"
    assert plan["url"] == "https://request.indy.gov/"
    assert plan["autofill_ready"] is False


def test_webform_plan_leaves_user_fields_for_the_phone():
    plan = build_submission(_pothole(agency_id="indot"))
    by_key = {field["key"]: field for field in plan["fields"]}
    assert by_key["first_name"]["value"] is None
    assert by_key["first_name"]["source"] == "user.first_name"


def test_required_location_and_description_are_never_empty():
    for agency in load_agencies():
        plan = build_submission(_pothole(agency_id=agency["id"]))
        for field in plan["fields"]:
            if field["required"] and not field["source"].startswith("user."):
                assert field["value"]


def test_email_plan():
    agency = {**get_channel(None, "Test"), "channel": "email", "email": "roads@example.com"}
    plan = build_submission(_pothole(), agency)
    assert plan["method"] == "email"
    assert plan["email"]["to"] == "roads@example.com"


def test_phone_plan_has_a_call_script():
    agency = {**get_channel(None, "Test"), "channel": "phone", "phone": "1-800-555-0100"}
    plan = build_submission(_pothole(), agency)
    assert plan["method"] == "phone"
    assert "pothole" in plan["call_script"]


def test_unknown_agency_plan_is_contact_only():
    assert build_submission(_pothole(agency_id="city:battle-ground"))["method"] == "contact_only"


def test_description_has_no_severity_opinions():
    description = build_submission(_pothole())["description"].lower()
    for word in ("severe", "dangerous", "bad", "large", "deep"):
        assert word not in description


def test_server_code_cannot_send_to_agencies():
    app_dir = Path(__file__).parent.parent / "app"
    for path in app_dir.glob("*.py"):
        source = path.read_text()
        for client in ("import requests", "import httpx", "urllib.request", "http.client", "smtplib"):
            assert client not in source, f"{path.name} uses {client}"


# ---------- duplicates and reporters ----------


def test_nearby_pothole_on_same_road_is_a_duplicate(conn, map_data):
    _insert(conn, map_data, "a")
    road = name_pothole(40.4201, -86.8800, map_data).road_name
    assert find_duplicate(conn, 40.4201, -86.88010, road, map_data) == "a"


def test_pothole_over_25_m_away_is_new(conn, map_data):
    _insert(conn, map_data, "a")
    assert find_duplicate(conn, 40.4201, -86.8796, "Main Street", map_data) is None


def test_nearby_pothole_on_a_different_road_is_new(conn, map_data):
    _insert(conn, map_data, "a")
    assert find_duplicate(conn, 40.4201, -86.88010, "Some Other Road", map_data) is None


def test_fixed_pothole_is_not_a_duplicate(conn, map_data):
    _insert(conn, map_data, "a", status="fixed")
    assert find_duplicate(conn, 40.4201, -86.8800, "Main Street", map_data) is None


def test_reporter_hash_differs_per_pothole_so_trips_cannot_be_linked():
    assert hash_reporter("device", "a", "s") != hash_reporter("device", "b", "s")
    assert hash_reporter("device", "a", "s") == hash_reporter("device", "a", "s")


def test_same_device_counts_once(conn, map_data):
    _insert(conn, map_data, "a")
    reporter = hash_reporter("device", "a", "s")
    assert add_detection(conn, "a", reporter, NOW) == 1
    assert add_detection(conn, "a", reporter, NOW) == 1
    assert add_detection(conn, "a", hash_reporter("other", "a", "s"), NOW) == 2


def test_detections_store_no_location_device_or_time_of_day(conn, map_data):
    _insert(conn, map_data, "a")
    add_detection(conn, "a", hash_reporter("device-xyz", "a", "s"), NOW)
    row = conn.execute("SELECT * FROM detections").fetchone()
    assert set(row.keys()) == {"pothole_id", "reporter_hash", "seen_on"}
    assert row["seen_on"] == "2026-11-07"
    assert "device-xyz" not in row["reporter_hash"]


def test_ask_to_send_rules():
    assert should_ask_to_send(3, False, "indot", 3)
    assert not should_ask_to_send(2, False, "indot", 3)
    assert not should_ask_to_send(3, True, "indot", 3)
    assert not should_ask_to_send(3, False, None, 3)


def test_mark_sent_only_counts_once(conn, map_data):
    _insert(conn, map_data, "a")
    assert mark_sent(conn, "a", "city:indianapolis", "open_form") is True
    assert mark_sent(conn, "a", "city:indianapolis", "open_form") is False


# ---------- priority ----------


def test_more_reporters_always_beats_tie_breakers():
    busy = priority_score(2, None, iso(NOW), NOW)
    old_highway = priority_score(1, "motorway", iso(NOW - timedelta(days=500)), NOW)
    assert busy["score"] > old_highway["score"]


def test_road_class_breaks_ties():
    assert priority_score(1, "primary", iso(NOW), NOW)["score"] > priority_score(1, "residential", iso(NOW), NOW)["score"]


def test_days_open_breaks_ties_and_is_capped():
    assert priority_score(1, None, iso(NOW - timedelta(days=20)), NOW)["days_open_points"] == 2
    assert priority_score(1, None, iso(NOW - timedelta(days=500)), NOW)["days_open_points"] == 3


def test_priority_shows_its_breakdown():
    p = priority_score(2, "secondary", iso(NOW - timedelta(days=10)), NOW)
    assert p == {"score": 23, "reporters": 2, "road_class_points": 2, "days_open_points": 1}


# ---------- photos ----------


def _photo_with_exif(orientation=None) -> bytes:
    image = Image.new("RGB", (40, 20), "gray")
    exif = image.getexif()
    exif[0x010F] = "SecretPhoneMaker"
    exif[0x0132] = "2026:11:07 10:00:00"
    if orientation:
        exif[0x0112] = orientation
    out = io.BytesIO()
    image.save(out, format="JPEG", exif=exif)
    return out.getvalue()


def test_exif_is_stripped():
    raw = _photo_with_exif()
    assert b"SecretPhoneMaker" in raw
    cleaned = clean_photo(raw)
    assert b"SecretPhoneMaker" not in cleaned
    assert len(Image.open(io.BytesIO(cleaned)).getexif()) == 0


def test_rotation_is_kept_after_stripping():
    cleaned = clean_photo(_photo_with_exif(orientation=6))
    assert Image.open(io.BytesIO(cleaned)).size == (20, 40)


def test_big_photo_is_shrunk():
    out = io.BytesIO()
    Image.new("RGB", (4000, 3000), "gray").save(out, format="JPEG")
    assert max(Image.open(io.BytesIO(clean_photo(out.getvalue()))).size) == 1600


def test_not_a_photo_is_rejected():
    with pytest.raises(BadPhoto):
        clean_photo(b"not an image")


# ---------- officials ----------


def test_empty_passcode_never_matches():
    assert not passcode_matches("", "")
    assert not token_matches(official_token("", "s"), "", "s")


def test_token_matches_only_the_right_passcode():
    token = official_token("right", "s")
    assert token_matches(token, "right", "s")
    assert not token_matches(token, "changed", "s")


def test_limiter_locks_after_too_many_failures():
    limiter = FailureLimiter()
    for _ in range(MAX_FAILURES):
        assert not limiter.locked()
        limiter.record_failure()
    assert limiter.locked()
