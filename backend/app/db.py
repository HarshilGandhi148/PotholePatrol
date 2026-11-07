"""SQLite storage: one file, no setup.

Privacy: `detections` has no location, no device id and no time of day. Reporters
are stored as a hash that is different for every pothole, and WITHOUT ROWID means
the table keeps no insertion order, so a drive can't be rebuilt from it.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS potholes (
    id TEXT PRIMARY KEY,
    lat REAL NOT NULL,
    lng REAL NOT NULL,
    title TEXT NOT NULL,
    road_name TEXT,
    cross_street TEXT,
    road_class TEXT,
    agency_id TEXT,
    agency_name TEXT,
    owner_kind TEXT NOT NULL,
    owner_reason TEXT NOT NULL,
    owner_confidence TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    first_seen TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    fixed_at TEXT,
    photo_file TEXT,
    source_id TEXT UNIQUE
);
CREATE INDEX IF NOT EXISTS potholes_location ON potholes (lat, lng);
CREATE INDEX IF NOT EXISTS potholes_queue ON potholes (agency_id, status);

CREATE TABLE IF NOT EXISTS detections (
    pothole_id TEXT NOT NULL REFERENCES potholes (id),
    reporter_hash TEXT NOT NULL,
    seen_on TEXT NOT NULL,
    PRIMARY KEY (pothole_id, reporter_hash)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS submissions (
    pothole_id TEXT PRIMARY KEY REFERENCES potholes (id),
    agency_id TEXT,
    method TEXT NOT NULL,
    sent_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS status_events (
    id INTEGER PRIMARY KEY,
    pothole_id TEXT NOT NULL REFERENCES potholes (id),
    status TEXT NOT NULL,
    changed_at TEXT NOT NULL
);
"""


def connect(path: str | Path) -> sqlite3.Connection:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[None]:
    """Hold the write lock, so two phones can't both create the same pothole."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")


def iso(moment: datetime) -> str:
    """UTC ISO 8601 with no fractions, which Swift's .iso8601 decoder requires."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso() -> str:
    return iso(datetime.now(timezone.utc))
