"""get_channel: how a given agency takes reports.

Agencies live in agencies.json, so adding one needs no code. Form fields are
placeholders (autofill_ready false) until they have a match_label or selector for
the app to find them. Agencies not in the file still get a "contact only" entry: no dead ends.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

AGENCIES_FILE = Path(__file__).parent / "agencies.json"

CHANNELS = {"webform", "email", "phone", "contact_only"}
FIELD_SOURCES = {"title", "description", "location_text", "location_search", "road_name", "cross_street", "lat", "lng", "first_seen", "photo_url"}


@lru_cache
def load_agencies() -> tuple[dict, ...]:
    return tuple(json.loads(AGENCIES_FILE.read_text()))


def get_channel(agency_id: str | None, agency_name: str | None = None) -> dict:
    for agency in load_agencies():
        if agency["id"] == agency_id:
            return agency
    return {
        "id": agency_id,
        "name": agency_name,
        "channel": "contact_only",
        "url": None,
        "phone": None,
        "email": None,
        "expected_response": None,
        "autofill_ready": False,
        "instructions": [],
        "fields": [],
    }
