"""Turning one detection into one pothole.

find_duplicate:     is this pothole already known? Same road, within 25 m, not fixed.
hash_reporter:      a different anonymous id for each device and pothole pair.
add_detection:      count a device once per pothole.
should_ask_to_send: has it been seen by enough devices to report it?
mark_sent:          remember a resident submitted it, so nobody reports it twice.
"""

from __future__ import annotations

import hashlib
import hmac
import sqlite3
from datetime import datetime

from .db import iso, now_iso
from .map_data import MapData
from .naming import PotholeName
from .owner import OwnerResult

DUPLICATE_DISTANCE_M = 25.0
# About 45 m of latitude, and 35 m of longitude in Indiana: a cheap first filter.
SEARCH_BOX_DEGREES = 0.0004


def find_duplicate(conn: sqlite3.Connection, lat: float, lng: float, road_name: str | None, data: MapData) -> str | None:
    rows = conn.execute(
        "SELECT id, lat, lng, road_name FROM potholes "
        "WHERE status != 'fixed' AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?",
        (lat - SEARCH_BOX_DEGREES, lat + SEARCH_BOX_DEGREES, lng - SEARCH_BOX_DEGREES, lng + SEARCH_BOX_DEGREES),
    ).fetchall()
    point = data.to_meters(lat, lng)
    best_id, best_distance = None, DUPLICATE_DISTANCE_M
    for row in rows:
        if road_name and row["road_name"] and road_name != row["road_name"]:
            continue
        distance = data.to_meters(row["lat"], row["lng"]).distance(point)
        if distance <= best_distance:
            best_id, best_distance = row["id"], distance
    return best_id


def hash_reporter(device_id: str, pothole_id: str, secret: str) -> str:
    message = f"{device_id}:{pothole_id}".encode()
    return hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()


def add_detection(conn: sqlite3.Connection, pothole_id: str, reporter_hash: str, captured_at: datetime) -> int:
    """Record the detection and return the number of distinct reporters."""
    conn.execute(
        "INSERT OR IGNORE INTO detections (pothole_id, reporter_hash, seen_on) VALUES (?, ?, ?)",
        (pothole_id, reporter_hash, iso(captured_at)[:10]),
    )
    conn.execute("UPDATE potholes SET updated_at = ? WHERE id = ?", (now_iso(), pothole_id))
    return conn.execute("SELECT COUNT(*) FROM detections WHERE pothole_id = ?", (pothole_id,)).fetchone()[0]


def should_ask_to_send(report_count: int, already_sent: bool, agency_id: str | None, threshold: int) -> bool:
    return agency_id is not None and not already_sent and report_count >= threshold


def mark_sent(conn: sqlite3.Connection, pothole_id: str, agency_id: str | None, method: str) -> bool:
    """Returns False if someone had already submitted this pothole."""
    cursor = conn.execute(
        "INSERT OR IGNORE INTO submissions (pothole_id, agency_id, method, sent_at) VALUES (?, ?, ?, ?)",
        (pothole_id, agency_id, method, now_iso()),
    )
    return cursor.rowcount == 1


def create_pothole(
    conn: sqlite3.Connection,
    pothole_id: str,
    lat: float,
    lng: float,
    owner: OwnerResult,
    name: PotholeName,
    first_seen: str,
    photo_file: str | None = None,
    status: str = "open",
    source_id: str | None = None,
) -> None:
    conn.execute(
        "INSERT INTO potholes (id, lat, lng, title, road_name, cross_street, road_class, agency_id, agency_name, "
        "owner_kind, owner_reason, owner_confidence, status, first_seen, updated_at, fixed_at, photo_file, source_id) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (
            pothole_id, lat, lng, name.title, name.road_name, name.cross_street, name.road_class,
            owner.agency_id, owner.agency_name, owner.kind, owner.reason, owner.confidence,
            status, first_seen, first_seen, first_seen if status == "fixed" else None, photo_file, source_id,
        ),
    )
