"""Golden tests for resolve_owner.

These use a small SYNTHETIC map near a city (straight roads, box-shaped
boundaries) in tests/fixtures/mini_city, so they run offline and fast.
Real-data tests are in test_owner_real.py.
"""

from pathlib import Path

import pytest

from app.map_data import MapData
from app.owner import resolve_owner, state_route_refs

FIXTURE = Path(__file__).parent / "fixtures" / "mini_city"


@pytest.fixture(scope="module")
def data() -> MapData:
    return MapData.from_dir(FIXTURE)


def test_state_route_inside_city_goes_to_indot(data):
    r = resolve_owner(40.400, -86.9000, data)  # on Sagamore Pkwy (US 52 / US 231) inside Lafayette
    assert r.agency_id == "indot"
    assert r.kind == "state"
    assert "US 52" in r.reason and "City of Indianapolis" in r.reason


def test_interstate_outside_city_goes_to_indot(data):
    r = resolve_owner(40.450, -86.8000, data)  # on I 65
    assert r.agency_id == "indot"
    assert r.road_name == "I 65"


def test_city_street_goes_to_city(data):
    r = resolve_owner(40.4201, -86.8800, data)  # on Main Street, about 11 m off the line
    assert r.agency_id == "city:indianapolis"
    assert r.agency_name == "City of Indianapolis"
    assert r.confidence == "high"


def test_town_street_says_town(data):
    r = resolve_owner(40.530, -86.960, data)
    assert r.agency_id == "city:battle-ground"
    assert r.agency_name == "Town of Battle Ground"


def test_county_road_outside_city_goes_to_county(data):
    r = resolve_owner(40.500, -86.850, data)  # County Road 300 N
    assert r.agency_id == "county:tippecanoe"
    assert r.kind == "county"


def test_parking_lot_is_private(data):
    r = resolve_owner(40.390, -86.8775, data)
    assert r.kind == "private"
    assert r.agency_id is None
    assert "parking lot" in r.reason


def test_private_road_is_private(data):
    r = resolve_owner(40.405, -86.8675, data)
    assert r.kind == "private"
    assert "private road" in r.reason


def test_pin_far_from_any_road_asks_user_to_move_pin(data):
    r = resolve_owner(40.380, -86.860, data)
    assert r.kind == "unknown"
    assert r.confidence == "low"
    assert "Drag the pin" in r.reason


def test_pin_20m_off_road_is_medium_confidence(data):
    r = resolve_owner(40.4202, -86.8800, data)  # about 22 m from Main Street
    assert r.agency_id == "city:indianapolis"
    assert r.confidence == "medium"


def test_intersection_of_state_and_city_road_is_medium_confidence(data):
    r = resolve_owner(40.4200, -86.9000, data)  # exactly where Main St meets Sagamore Pkwy
    assert r.confidence == "medium"


@pytest.mark.parametrize(
    "ref, expected",
    [
        ("US 231", ["US 231"]),
        ("US 52;US 231", ["US 52", "US 231"]),
        ("I 65", ["I 65"]),
        ("IN 26", ["IN 26"]),
        ("SR 25", ["SR 25"]),
        ("CR 300N", []),
        (None, []),
    ],
)
def test_state_route_refs(ref, expected):
    assert state_route_refs(ref) == expected
