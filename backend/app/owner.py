"""Function 1: work out who owns the road at a point.

Plain English: given a GPS point, find the road the pothole is on, then decide
who is responsible for fixing it, in this order:

1. State road (interstate, US route, Indiana state route)  -> INDOT,
   even when it runs through a city.
2. Private road, driveway or parking lot                   -> nobody public.
3. Inside a city or town's boundary                        -> that city or town.
4. Otherwise                                               -> the county.

It also returns the reason in plain words, so the app can show residents
*why* a report is going where it is going.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from shapely.geometry import Point

from .map_data import MapData, Road, state_route_refs  # noqa: F401

# How far (meters) a pin can be from a road and still count as "on" it.
MAX_ROAD_DISTANCE_M = 30.0
# Beyond this distance we are less sure the pin is on the right road.
CLOSE_DISTANCE_M = 15.0
# If two roads with different owners are this close in distance, it is an
# intersection and we flag lower confidence.
INTERSECTION_MARGIN_M = 8.0

PRIVATE_ACCESS = {"private", "no", "customers", "permit"}
PRIVATE_SERVICE = {"driveway", "parking_aisle", "drive-through", "parking"}


@dataclass(frozen=True)
class OwnerResult:
    agency_id: str | None      # e.g. "indot", "city:indianapolis", "county:hamilton"
    agency_name: str | None    # e.g. "City of Indianapolis"
    kind: str                  # "state" | "city" | "county" | "private" | "unknown"
    reason: str                # plain-English explanation for the resident
    confidence: str            # "high" | "medium" | "low"
    road_name: str | None      # e.g. "US 231" or "Main Street"


def is_private(road: Road) -> bool:
    return road.access in PRIVATE_ACCESS or road.service in PRIVATE_SERVICE


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _owner_kind(road: Road, point: Point, data: MapData) -> str:
    """Owner category for a road at a point, used to spot ambiguous intersections."""
    if road.state_routes:
        return "state"
    if is_private(road):
        return "private"
    return "city" if data.city_at(point) else "county"


def resolve_owner(lat: float, lng: float, data: MapData) -> OwnerResult:
    point = data.to_meters(lat, lng)

    nearest = data.roads_near(point, MAX_ROAD_DISTANCE_M)
    if not nearest and not data.covers(point):
        return OwnerResult(
            agency_id=None,
            agency_name=None,
            kind="unknown",
            reason="We don't cover this area yet.",
            confidence="low",
            road_name=None,
        )

    if not nearest:
        return OwnerResult(
            agency_id=None,
            agency_name=None,
            kind="unknown",
            reason=(
                f"We couldn't find a road within {int(MAX_ROAD_DISTANCE_M)} m of this pin. "
                "Drag the pin onto the road where the pothole is."
            ),
            confidence="low",
            road_name=None,
        )

    road, distance = nearest[0]
    confidence = "high" if distance <= CLOSE_DISTANCE_M else "medium"

    # Intersection check: another road with a different owner almost as close.
    my_kind = _owner_kind(road, point, data)
    for other, other_distance in nearest[1:]:
        if other_distance - distance > INTERSECTION_MARGIN_M:
            break
        if _owner_kind(other, point, data) != my_kind:
            confidence = "medium"
            break

    road_label = road.display_name

    # 1. State road -> INDOT
    refs = road.state_routes
    if refs:
        route = refs[0]
        city = data.city_at(point)
        where = f" even though it runs through {city.display_name}" if city else ""
        return OwnerResult(
            agency_id="indot",
            agency_name="Indiana Department of Transportation (INDOT)",
            kind="state",
            reason=f"This is on {route}, a state route, so INDOT maintains it{where}.",
            confidence=confidence,
            road_name=road_label,
        )

    # 2. Private road / parking lot
    if is_private(road):
        what = "a parking lot or driveway" if road.service in PRIVATE_SERVICE else "a private road"
        return OwnerResult(
            agency_id=None,
            agency_name=None,
            kind="private",
            reason=(
                f"This looks like {what}. Cities and counties can't repair private property, "
                "so contact the property owner, landlord or HOA."
            ),
            confidence="medium",
            road_name=road_label,
        )

    # 3. Inside a city or town
    city = data.city_at(point)
    if city:
        return OwnerResult(
            agency_id=f"city:{_slug(city.short_name)}",
            agency_name=city.display_name,
            kind="city",
            reason=f"This is inside {city.display_name} limits and is not a state road.",
            confidence=confidence,
            road_name=road_label,
        )

    # 4. County
    county = data.county_at(point)
    if county:
        return OwnerResult(
            agency_id=f"county:{_slug(county.name)}",
            agency_name=f"{county.name} County Highway Department",
            kind="county",
            reason=f"This is outside city limits, so {county.name} County maintains it.",
            confidence=confidence,
            road_name=road_label,
        )

    return OwnerResult(
        agency_id=None,
        agency_name=None,
        kind="unknown",
        reason="This point is outside the area we have map data for.",
        confidence="low",
        road_name=road_label,
    )
