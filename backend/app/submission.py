"""build_submission: the send plan the app follows.

The server never contacts an agency. It tells the app what to open and what to
fill in, and the resident taps the agency's own Submit.
"""

from __future__ import annotations

from .agencies import get_channel

METHOD_BY_CHANNEL = {"webform": "open_form", "email": "email", "phone": "phone"}


def describe(pothole: dict) -> str:
    """Facts only: location, report count, first seen date. No severity opinions."""
    reports = pothole["report_count"]
    noun = "report" if reports == 1 else "reports"
    return (
        f"{pothole['title']}. GPS {pothole['lat']:.5f}, {pothole['lng']:.5f}. "
        f"{reports} {noun} through PotholePatrol, first seen {pothole['first_seen'][:10]}."
    )


def _location_text(pothole: dict) -> str:
    road = pothole.get("road_name") or "Unnamed road"
    cross = pothole.get("cross_street")
    where = f"{road} near {cross}" if cross else road
    return f"{where} ({pothole['lat']:.5f}, {pothole['lng']:.5f})"


def build_submission(pothole: dict, agency: dict | None = None) -> dict:
    agency = agency or get_channel(pothole.get("agency_id"), pothole.get("agency_name"))
    description = describe(pothole)
    values = {
        **pothole,
        "description": description,
        "location_text": _location_text(pothole),
        "location_search": f"{pothole['lat']:.5f}, {pothole['lng']:.5f}",
    }
    method = METHOD_BY_CHANNEL.get(agency["channel"], "contact_only")
    if method == "open_form" and not agency["url"]:
        method = "contact_only"

    email = None
    if method == "email":
        email = {"to": agency["email"], "subject": pothole["title"], "body": description}

    call_script = None
    if agency.get("phone"):
        call_script = f"I'd like to report a pothole. {description}"

    return {
        "method": method,
        "agency_id": agency["id"],
        "agency_name": agency["name"],
        "url": agency["url"],
        "phone": agency["phone"],
        "email": email,
        "title": pothole["title"],
        "description": description,
        "copy_text": f"{pothole['title']}\n{description}",
        "call_script": call_script,
        "expected_response": agency["expected_response"],
        "autofill_ready": agency["autofill_ready"],
        "instructions": agency["instructions"],
        # user.* values stay on the phone: value is null and the app fills them in.
        "fields": [
            {
                "key": field["key"],
                "label": field["label"],
                "step": field.get("step", 1),
                "match_label": field.get("match_label"),
                "selector": field["selector"],
                "required": field["required"],
                "source": field["source"],
                "value": values.get(field["source"]),
            }
            for field in agency["fields"]
        ],
    }
