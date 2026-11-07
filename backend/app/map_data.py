"""Loads the map files the owner lookup needs and answers simple map questions.

Three GeoJSON files live in one folder:
- roads.geojson     road lines from OpenStreetMap (tags: name, ref, highway, access, service)
- cities.geojson    city and town boundaries from the US Census (fields: NAME, NAMELSAD)
- counties.geojson  county boundaries from the US Census (field: NAME)

Everything is converted to meters (UTM zone 16N, which covers Indiana) so
distances like "30 m from the road" are real distances.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace
from pathlib import Path

from pyproj import Transformer
import shapely
from shapely.geometry import Point, shape
from shapely.geometry.base import BaseGeometry
from shapely.strtree import STRtree

# WGS84 lat/lng -> UTM zone 16N (meters). Indiana sits inside zone 16.
_TO_METERS = Transformer.from_crs("EPSG:4326", "EPSG:32616", always_xy=True)
_TO_LAT_LNG = Transformer.from_crs("EPSG:32616", "EPSG:4326", always_xy=True)

# With no road this close, the point is outside the area we downloaded.
COVERAGE_DISTANCE_M = 2000.0

# Same pattern as OSM refs like "US 231"; also used to find routes on a road's ref tag.
STATE_ROUTE_RE = re.compile(r"^(I|US|IN|SR)[\s-]*\d+[A-Z]?$", re.IGNORECASE)


def _project(geom: BaseGeometry) -> BaseGeometry:
    return shapely.transform(geom, lambda x, y: _TO_METERS.transform(x, y), interleaved=False)


def to_lat_lng(x: float, y: float) -> tuple[float, float]:
    lng, lat = _TO_LAT_LNG.transform(x, y)
    return lat, lng


def state_route_refs(ref: str | None) -> list[str]:
    """Return the state-maintained route numbers in an OSM ref tag.

    OSM can list several routes on one road, e.g. "US 52;US 231".
    """
    if not ref:
        return []
    parts = [p.strip() for p in ref.split(";")]
    return [p for p in parts if STATE_ROUTE_RE.match(p)]


def is_incorporated(lsad: str) -> bool:
    """True for real cities and towns. Census "CDP" places have no government."""
    return "CDP" not in lsad


@dataclass(frozen=True)
class Road:
    geom: BaseGeometry
    name: str | None
    ref: str | None
    highway: str | None
    access: str | None
    service: str | None
    state_route: str | None = None  # route from an OSM relation, or inherited by a ramp

    @property
    def state_routes(self) -> list[str]:
        """Every state route on this road, from its ref tag or its relation."""
        routes = state_route_refs(self.ref)
        if self.state_route and self.state_route not in routes:
            routes.append(self.state_route)
        return routes

    @property
    def display_name(self) -> str | None:
        first_ref = self.ref.split(";")[0].strip() if self.ref else self.state_route
        if self.name and first_ref:
            return f"{self.name} ({first_ref})"
        return self.name or first_ref


@dataclass(frozen=True)
class Area:
    geom: BaseGeometry
    name: str
    lsad: str  # Census legal description, e.g. "Fishers city", "Speedway town"

    @property
    def short_name(self) -> str:
        # Census calls the main part of Indianapolis "Indianapolis city (balance)".
        return re.sub(r"\s+city \(balance\)$", "", self.name)

    @property
    def display_name(self) -> str:
        is_town = self.lsad.lower().endswith(" town")
        return f"Town of {self.short_name}" if is_town else f"City of {self.short_name}"


class MapData:
    def __init__(self, roads: list[Road], cities: list[Area], counties: list[Area]):
        self.roads = mark_state_links(roads)
        self.cities = [c for c in cities if is_incorporated(c.lsad)]
        self.counties = counties
        self._road_tree = STRtree([r.geom for r in self.roads])
        self._city_tree = STRtree([c.geom for c in self.cities])
        self._county_tree = STRtree([c.geom for c in counties])

    # ---------- loading ----------

    @classmethod
    def from_dir(cls, folder: str | Path) -> "MapData":
        folder = Path(folder)
        roads = [
            Road(
                geom=_project(shape(f["geometry"])),
                name=f["properties"].get("name"),
                ref=f["properties"].get("ref"),
                highway=f["properties"].get("highway"),
                access=f["properties"].get("access"),
                service=f["properties"].get("service"),
                state_route=f["properties"].get("state_route"),
            )
            for f in _features(folder / "roads.geojson")
        ]
        cities = [_area(f) for f in _features(folder / "cities.geojson")]
        counties = [_area(f) for f in _features(folder / "counties.geojson")]
        return cls(roads, cities, counties)

    # ---------- questions ----------

    @staticmethod
    def to_meters(lat: float, lng: float) -> Point:
        x, y = _TO_METERS.transform(lng, lat)
        return Point(x, y)

    def roads_near(self, point: Point, max_distance_m: float) -> list[tuple[Road, float]]:
        """Roads within max_distance_m of the point, closest first."""
        idx = self._road_tree.query(point.buffer(max_distance_m))
        found = [(self.roads[i], self.roads[i].geom.distance(point)) for i in idx]
        found = [(r, d) for r, d in found if d <= max_distance_m]
        return sorted(found, key=lambda rd: rd[1])

    def covers(self, point: Point) -> bool:
        """True if there are roads nearby, meaning we downloaded this area."""
        return len(self._road_tree.query(point.buffer(COVERAGE_DISTANCE_M))) > 0

    def city_at(self, point: Point) -> Area | None:
        return _containing(self._city_tree, self.cities, point)

    def county_at(self, point: Point) -> Area | None:
        return _containing(self._county_tree, self.counties, point)


def mark_state_links(roads: list[Road]) -> list[Road]:
    """Give ramps the route of the state road they connect to.

    Ramps (highway=*_link) carry no route number in OSM, but they belong to the
    state road they join. A ramp can be several pieces, so keep passing the route
    along until nothing changes.
    """
    route_at: dict[tuple[float, float], str] = {}
    for road in roads:
        if road.state_routes:
            for xy in road.geom.coords:
                route_at[xy] = road.state_routes[0]

    marked = list(roads)
    changed = True
    while changed:
        changed = False
        for i, road in enumerate(marked):
            if road.state_routes or not (road.highway or "").endswith("_link"):
                continue
            route = next((route_at[xy] for xy in road.geom.coords if xy in route_at), None)
            if route:
                marked[i] = replace(road, state_route=route)
                route_at.update((xy, route) for xy in road.geom.coords)
                changed = True
    return marked


def _features(path: Path) -> list[dict]:
    with open(path) as fh:
        return json.load(fh)["features"]


def _area(feature: dict) -> Area:
    props = feature["properties"]
    name = props.get("NAME") or props.get("name")
    return Area(
        geom=_project(shape(feature["geometry"])),
        name=name,
        lsad=props.get("NAMELSAD") or name,
    )


def _containing(tree: STRtree, areas: list[Area], point: Point) -> Area | None:
    for i in tree.query(point, predicate="within"):
        return areas[i]
    return None
