"""Tests for the state road fixes.

Real OpenStreetMap data often keeps a route number on a "route relation" rather
than on the road itself, and ramps have no route number at all. These tests build
tiny maps in memory so they stay offline and fast.
"""

from shapely.geometry import LineString, box

from app.map_data import Area, MapData, Road, is_incorporated, mark_state_links
from app.owner import resolve_owner


def _road(coords, **tags) -> Road:
    fields = dict(name=None, ref=None, highway="primary", access=None, service=None, state_route=None)
    return Road(geom=LineString(coords), **{**fields, **tags})


def _map(roads, cities=()) -> MapData:
    return MapData(list(roads), list(cities), [])


def _lat_lng(data: MapData, x: float, y: float) -> tuple[float, float]:
    from app.map_data import to_lat_lng

    return to_lat_lng(x, y)


def test_route_from_relation_goes_to_indot_with_no_ref_tag():
    road = _road([(500000, 4470000), (500000, 4471000)], name="Sagamore Parkway West", state_route="US 52")
    data = _map([road])
    lat, lng = _lat_lng(data, 500000, 4470500)
    r = resolve_owner(lat, lng, data)
    assert r.agency_id == "indot"
    assert "US 52" in r.reason


def test_ramp_touching_a_state_route_is_state():
    highway = _road([(0, 0), (0, 50), (0, 100)], highway="motorway", ref="I 65")
    ramp = _road([(0, 50), (20, 80)], highway="motorway_link")
    marked = mark_state_links([highway, ramp])
    assert marked[1].state_route == "I 65"


def test_ramp_chain_inherits_the_route():
    highway = _road([(0, 0), (0, 50), (0, 100)], highway="motorway", ref="I 65")
    first = _road([(0, 50), (20, 80)], highway="motorway_link")
    second = _road([(20, 80), (40, 90)], highway="motorway_link")
    marked = mark_state_links([second, first, highway])
    assert marked[0].state_route == "I 65"


def test_link_between_local_roads_stays_local():
    street = _road([(0, 0), (0, 50), (0, 100)], highway="secondary")
    link = _road([(0, 50), (20, 80)], highway="secondary_link")
    assert mark_state_links([street, link])[1].state_route is None


def test_ordinary_road_touching_a_state_route_stays_local():
    highway = _road([(0, 0), (0, 50), (0, 100)], ref="US 52")
    street = _road([(0, 50), (20, 80)], highway="residential")
    assert mark_state_links([highway, street])[1].state_route is None


def test_census_designated_places_are_not_cities():
    assert is_incorporated("Lafayette city")
    assert is_incorporated("Battle Ground town")
    assert is_incorporated("Indianapolis city (balance)")
    assert not is_incorporated("Americus CDP")


def test_road_inside_a_cdp_goes_to_county_not_city():
    area = Area(geom=box(499000, 4469000, 501000, 4472000), name="Americus", lsad="Americus CDP")
    road = _road([(500000, 4470000), (500000, 4471000)], highway="residential")
    data = MapData([road], [area], [])
    lat, lng = _lat_lng(data, 500000, 4470500)
    assert resolve_owner(lat, lng, data).kind != "city"


def test_city_named_with_town_is_still_a_city():
    area = Area(geom=box(0, 0, 1, 1), name="Charlestown", lsad="Charlestown city")
    assert area.display_name == "City of Charlestown"


def test_indianapolis_balance_gets_a_clean_name():
    area = Area(geom=box(0, 0, 1, 1), name="Indianapolis city (balance)", lsad="Indianapolis city (balance)")
    assert area.display_name == "City of Indianapolis"
    assert area.short_name == "Indianapolis"


def test_pin_outside_road_coverage_says_so():
    road = _road([(500000, 4470000), (500000, 4471000)])
    data = _map([road])
    r = resolve_owner(41.0793, -85.1394, data)  # Fort Wayne
    assert r.kind == "unknown"
    assert "don't cover" in r.reason


def test_routes_by_way_reads_relations():
    import importlib.util
    from pathlib import Path

    path = Path(__file__).parent.parent / "scripts" / "fetch_map_data.py"
    spec = importlib.util.spec_from_file_location("fetch_map_data", path)
    fetch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fetch)

    relations = [
        {"tags": {"network": "US:US", "ref": "52"}, "members": [{"type": "way", "ref": 1}]},
        {"tags": {"network": "US:IN", "ref": "26"}, "members": [{"type": "way", "ref": 2}, {"type": "node", "ref": 3}]},
        {"tags": {"network": "US:IN"}, "members": [{"type": "way", "ref": 4}]},
    ]
    assert fetch.routes_by_way(relations) == {1: "US 52", 2: "SR 26"}
