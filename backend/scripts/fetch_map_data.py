"""Download the real map data that resolve_owner needs.

Run once on your laptop (it needs internet):

    python scripts/fetch_map_data.py                # Indianapolis and Fishers (default)
    python scripts/fetch_map_data.py --region indy  # Indianapolis only

Writes three files to backend/data/:
- roads.geojson     roads in the chosen regions, from OpenStreetMap (Overpass API)
- cities.geojson    every Indiana city and town boundary, from US Census TIGER
- counties.geojson  every Indiana county boundary, from US Census TIGER
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# (south, west, north, east) bounding boxes for the MVP regions.
REGIONS = {
    "indy": (39.63, -86.33, 39.93, -85.94),        # Indianapolis (Marion County) incl. Lawrence
    "fishers": (39.92, -86.08, 40.02, -85.85),
}

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
TIGER = "https://www2.census.gov/geo/tiger/TIGER2024"
INDIANA_FIPS = "18"

# Road types we ignore: not places a pothole report would go.
SKIP_HIGHWAY = "footway|path|cycleway|steps|pedestrian|track|bridleway|corridor|proposed|construction|platform"
KEEP_TAGS = ("name", "ref", "highway", "access", "service")

USER_AGENT = "PotholePatrol hackathon project (map data fetch)"

# OSM route networks that the state maintains, and how we write their route numbers.
ROUTE_PREFIX = {"US:I": "I", "US:US": "US", "US:IN": "SR"}


def _get(url: str, data: bytes | None = None) -> bytes:
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def _overpass(query: str) -> list[dict]:
    """Run an Overpass query. The public server often returns 502, so retry."""
    body = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(5):
        try:
            return json.loads(_get(OVERPASS_URL, body))["elements"]
        except urllib.error.HTTPError as err:
            if err.code < 500 and err.code != 429 or attempt == 4:
                raise
            time.sleep(5 * (attempt + 1))
    return []


def routes_by_way(relations: list[dict]) -> dict[int, str]:
    """Map each OSM way id to its state route, from route relations.

    Many state roads keep their number on the relation, not on the road itself.
    """
    routes: dict[int, str] = {}
    for rel in relations:
        tags = rel.get("tags", {})
        prefix = ROUTE_PREFIX.get(tags.get("network"))
        number = tags.get("ref")
        if not prefix or not number:
            continue
        for member in rel.get("members", []):
            if member.get("type") == "way":
                routes.setdefault(member["ref"], f"{prefix} {number}")
    return routes


def fetch_state_routes(bbox: tuple[float, float, float, float]) -> dict[int, str]:
    s, w, n, e = bbox
    query = f'[out:json][timeout:180];relation["route"="road"]["network"~"^US:(I|US|IN)$"]({s},{w},{n},{e});out body;'
    return routes_by_way(_overpass(query))


def fetch_roads(bbox: tuple[float, float, float, float]) -> list[dict]:
    s, w, n, e = bbox
    query = (
        "[out:json][timeout:180];"
        f'way["highway"]["highway"!~"{SKIP_HIGHWAY}"]({s},{w},{n},{e});'
        "out tags geom;"
    )
    routes = fetch_state_routes(bbox)
    features = []
    for el in _overpass(query):
        if el.get("type") != "way" or "geometry" not in el:
            continue
        coords = [[pt["lon"], pt["lat"]] for pt in el["geometry"]]
        if len(coords) < 2:
            continue
        tags = el.get("tags", {})
        props = {"osm_id": el["id"], **{k: tags[k] for k in KEEP_TAGS if k in tags}}
        if el["id"] in routes:
            props["state_route"] = routes[el["id"]]
        features.append(
            {
                "type": "Feature",
                "properties": props,
                "geometry": {"type": "LineString", "coordinates": coords},
            }
        )
    return features


def fetch_tiger(url: str, keep_fields: tuple[str, ...], state_only: bool) -> list[dict]:
    import shapefile  # pip install pyshp

    raw = _get(url)
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        stem = next(n for n in zf.namelist() if n.endswith(".shp"))[:-4]
        reader = shapefile.Reader(
            shp=io.BytesIO(zf.read(stem + ".shp")),
            shx=io.BytesIO(zf.read(stem + ".shx")),
            dbf=io.BytesIO(zf.read(stem + ".dbf")),
        )
        features = []
        for sr in reader.iterShapeRecords():
            rec = sr.record.as_dict()
            if state_only and rec.get("STATEFP") != INDIANA_FIPS:
                continue
            features.append(
                {
                    "type": "Feature",
                    "properties": {k: rec[k] for k in keep_fields if k in rec},
                    "geometry": sr.shape.__geo_interface__,
                }
            )
    return features


def _write(name: str, features: list[dict]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    path = DATA_DIR / f"{name}.geojson"
    with open(path, "w") as fh:
        json.dump({"type": "FeatureCollection", "features": features}, fh)
    print(f"  wrote {len(features):>6} features -> {path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", action="append", choices=[*REGIONS, "all"], help="repeatable")
    args = ap.parse_args()
    regions = list(REGIONS) if not args.region or "all" in args.region else args.region

    print(f"Roads from OpenStreetMap for: {', '.join(regions)}")
    roads, seen = [], set()
    for r in regions:
        for f in fetch_roads(REGIONS[r]):
            if f["properties"]["osm_id"] not in seen:
                seen.add(f["properties"]["osm_id"])
                roads.append(f)
    _write("roads", roads)

    print("City and town boundaries from US Census")
    _write("cities", fetch_tiger(f"{TIGER}/PLACE/tl_2024_{INDIANA_FIPS}_place.zip", ("NAME", "NAMELSAD", "GEOID"), False))

    print("County boundaries from US Census (large download, about 80 MB)")
    _write("counties", fetch_tiger(f"{TIGER}/COUNTY/tl_2024_us_county.zip", ("NAME", "NAMELSAD", "GEOID"), True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
