"""Golden tests on the real downloaded map.

Expected owners were checked against INDOT's route layer: East Washington Street
is US 40 outside I-465 and a plain city street inside it.
These skip when backend/data/ is missing, so CI stays offline.
"""

from pathlib import Path

import pytest

from app.map_data import MapData
from app.owner import resolve_owner

DATA = Path(__file__).parent.parent / "data"

pytestmark = pytest.mark.skipif(not (DATA / "roads.geojson").exists(), reason="run scripts/fetch_map_data.py first")


@pytest.fixture(scope="module")
def data() -> MapData:
    return MapData.from_dir(DATA)


@pytest.mark.parametrize(
    "label, lat, lng, agency_id",
    [
        ("E Washington St outside I-465 is US 40", 39.77309, -86.02417, "indot"),
        ("SR 37 in Fishers", 39.98069, -86.00374, "indot"),
        ("E Washington St downtown", 39.76689, -86.14951, "city:indianapolis"),
        ("E Washington St inside I-465", 39.77079, -86.07055, "city:indianapolis"),
        ("Massachusetts Avenue", 39.77190, -86.15338, "city:indianapolis"),
        ("116th Street in Fishers", 39.95684, -86.02938, "city:fishers"),
        ("56th Street in Lawrence", 39.85582, -85.97718, "city:lawrence"),
    ],
)
def test_real_owner(data, label, lat, lng, agency_id):
    assert resolve_owner(lat, lng, data).agency_id == agency_id, label


@pytest.mark.parametrize("label, lat, lng", [("Lafayette", 40.4167, -86.8753), ("Carmel", 39.9784, -86.1180)])
def test_outside_coverage(data, label, lat, lng):
    assert "don't cover" in resolve_owner(lat, lng, data).reason, label
