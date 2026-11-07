"""name_pothole: a factual name based on location, never an opinion.

Plain English: take the closest named road, then the closest different named road
within 300 m as the cross street: "Pothole on Main Street near 5th Street".
"""

from __future__ import annotations

from dataclasses import dataclass

from .map_data import MapData
from .owner import MAX_ROAD_DISTANCE_M, is_private

CROSS_STREET_DISTANCE_M = 300.0


@dataclass(frozen=True)
class PotholeName:
    title: str
    road_name: str | None
    cross_street: str | None
    road_class: str | None     # OSM highway type, used for priority tie-breaks


def name_pothole(lat: float, lng: float, data: MapData) -> PotholeName:
    point = data.to_meters(lat, lng)
    close = data.roads_near(point, MAX_ROAD_DISTANCE_M)
    road_class = close[0][0].highway if close else None
    road = next((r for r, _ in close if r.display_name), None)
    if road is None:
        return PotholeName("Pothole on an unnamed road", None, None, road_class)

    cross = None
    for other, _ in data.roads_near(point, CROSS_STREET_DISTANCE_M):
        is_ramp = (other.highway or "").endswith("_link")
        if other.name and other.name != road.name and not is_private(other) and not is_ramp:
            cross = other.name
            break

    title = f"Pothole on {road.display_name}"
    return PotholeName(f"{title} near {cross}" if cross else title, road.display_name, cross, road_class)
