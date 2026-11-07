"""priority_score: simple math that officials can check by hand.

Each distinct reporter is worth 10 points. Road class and days open add at most
3 points each, so they only ever break ties between equal reporter counts.
"""

from __future__ import annotations

from datetime import datetime, timezone

POINTS_PER_REPORTER = 10
ROAD_CLASS_POINTS = {
    "motorway": 3, "motorway_link": 3, "trunk": 3, "trunk_link": 3, "primary": 3, "primary_link": 3,
    "secondary": 2, "secondary_link": 2,
    "tertiary": 1, "tertiary_link": 1,
}
MAX_DAYS_POINTS = 3
DAYS_PER_POINT = 10


def priority_score(reporters: int, road_class: str | None, first_seen: str, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    opened = datetime.fromisoformat(first_seen.replace("Z", "+00:00"))
    days_open = max((now - opened).days, 0)
    road_points = ROAD_CLASS_POINTS.get(road_class or "", 0)
    days_points = min(days_open // DAYS_PER_POINT, MAX_DAYS_POINTS)
    return {
        "score": reporters * POINTS_PER_REPORTER + road_points + days_points,
        "reporters": reporters,
        "road_class_points": road_points,
        "days_open_points": days_points,
    }
