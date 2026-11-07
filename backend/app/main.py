"""The API the iOS app calls. See docs/API.md for the contract.

JSON keys are snake_case, dates are UTC ISO 8601 and photo_url is a full HTTPS URL.
Run with: uvicorn app.main:app --port 8000
"""

import json
import logging
import math
import sqlite3
import time
from collections.abc import Iterator
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .agencies import get_channel, load_agencies
from .config import Settings
from .db import connect, init_db, iso, now_iso, transaction
from .detections import (
    add_detection,
    create_pothole,
    find_duplicate,
    hash_reporter,
    mark_sent,
    should_ask_to_send,
)
from .map_data import MapData
from .naming import name_pothole
from .officials import FailureLimiter, official_token, passcode_matches, token_matches
from .owner import resolve_owner
from .photos import BadPhoto, clean_photo
from .priority import priority_score
from .submission import build_submission

log = logging.getLogger("potholepatrol")

Status = Literal["open", "acknowledged", "fixed"]

POTHOLE_SQL = """
SELECT p.*,
       (SELECT COUNT(*) FROM detections d WHERE d.pothole_id = p.id) AS report_count,
       EXISTS (SELECT 1 FROM submissions s WHERE s.pothole_id = p.id) AS sent
FROM potholes p
"""


class VerifyRequest(BaseModel):
    passcode: str = Field(max_length=200)


class StatusUpdate(BaseModel):
    status: Status


class SendRequest(BaseModel):
    method: Literal["open_form", "email", "phone"]


def create_app(settings: Settings | None = None, map_data: MapData | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.photo_dir.mkdir(parents=True, exist_ok=True)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.map_data = map_data or MapData.from_dir(settings.data_dir)
        conn = connect(settings.db_path)
        init_db(conn)
        conn.close()
        yield

    app = FastAPI(title="PotholePatrol", lifespan=lifespan)
    app.mount("/photos", StaticFiles(directory=settings.photo_dir), name="photos")
    limiter = FailureLimiter()

    @app.middleware("http")
    async def log_requests(request: Request, call_next):
        # Path and status only: never log locations or device ids.
        started = time.perf_counter()
        response = await call_next(request)
        log.info(json.dumps({
            "method": request.method,
            "path": request.url.path,
            "status": response.status_code,
            "ms": round((time.perf_counter() - started) * 1000, 1),
        }))
        return response

    def get_conn() -> Iterator[sqlite3.Connection]:
        conn = connect(settings.db_path)
        try:
            yield conn
        finally:
            conn.close()

    Conn = Annotated[sqlite3.Connection, Depends(get_conn)]

    def require_official(x_official_token: Annotated[str | None, Header()] = None) -> None:
        if not token_matches(x_official_token, settings.official_passcode, settings.reporter_secret):
            raise HTTPException(401, "Official sign-in required")

    def base_url(request: Request) -> str:
        if settings.public_base_url:
            return settings.public_base_url
        return str(request.base_url).rstrip("/").replace("http://", "https://", 1)

    def pothole_json(row: sqlite3.Row, request: Request) -> dict:
        photo_url = f"{base_url(request)}/photos/{row['photo_file']}" if row["photo_file"] else None
        return {
            "id": row["id"],
            "title": row["title"],
            "lat": row["lat"],
            "lng": row["lng"],
            "road_name": row["road_name"],
            "cross_street": row["cross_street"],
            "status": row["status"],
            "report_count": row["report_count"],
            "sent": bool(row["sent"]),
            "first_seen": row["first_seen"],
            "updated_at": row["updated_at"],
            "fixed_at": row["fixed_at"],
            "photo_url": photo_url,
            "owner": {
                "agency_id": row["agency_id"],
                "agency_name": row["agency_name"],
                "kind": row["owner_kind"],
                "reason": row["owner_reason"],
                "confidence": row["owner_confidence"],
            },
            "priority": priority_score(row["report_count"], row["road_class"], row["first_seen"]),
        }

    def load_pothole(conn: sqlite3.Connection, pothole_id: str) -> sqlite3.Row:
        row = conn.execute(f"{POTHOLE_SQL} WHERE p.id = ?", (pothole_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Pothole not found")
        return row

    def send_plan_for(pothole: dict) -> dict | None:
        if pothole["owner"]["agency_id"] is None:
            return None
        return build_submission({**pothole, **pothole["owner"]})

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.post("/detections")
    def post_detection(
        request: Request,
        conn: Conn,
        photo: Annotated[UploadFile, File()],
        lat: Annotated[float, Form(ge=-90, le=90)],
        lng: Annotated[float, Form(ge=-180, le=180)],
        captured_at: Annotated[datetime, Form()],
        device_id: Annotated[str, Form(min_length=8, max_length=128)],
    ) -> dict:
        if not (math.isfinite(lat) and math.isfinite(lng)):
            raise HTTPException(422, "lat and lng must be real numbers")
        if captured_at.tzinfo is None:
            captured_at = captured_at.replace(tzinfo=timezone.utc)
        if captured_at > datetime.now(timezone.utc) + timedelta(days=1):
            raise HTTPException(422, "captured_at is in the future")

        raw = photo.file.read(settings.max_photo_bytes + 1)
        if len(raw) > settings.max_photo_bytes:
            raise HTTPException(413, "Photo is too large")
        try:
            cleaned = clean_photo(raw)
        except BadPhoto as err:
            raise HTTPException(422, str(err)) from err

        data: MapData = request.app.state.map_data
        owner = resolve_owner(lat, lng, data)
        name = name_pothole(lat, lng, data)

        with transaction(conn):
            pothole_id = find_duplicate(conn, lat, lng, name.road_name, data)
            is_new = pothole_id is None
            if is_new:
                pothole_id = uuid4().hex
                photo_file = f"{pothole_id}.jpg"
                (settings.photo_dir / photo_file).write_bytes(cleaned)
                create_pothole(conn, pothole_id, lat, lng, owner, name, iso(captured_at), photo_file)
            add_detection(conn, pothole_id, hash_reporter(device_id, pothole_id, settings.reporter_secret), captured_at)

        pothole = pothole_json(load_pothole(conn, pothole_id), request)
        ask = should_ask_to_send(
            pothole["report_count"], pothole["sent"], pothole["owner"]["agency_id"], settings.send_threshold
        )
        return {
            "pothole_id": pothole_id,
            "is_new": is_new,
            "pothole": pothole,
            "ask_to_send": ask,
            "send_plan": send_plan_for(pothole) if ask else None,
        }

    @app.get("/potholes")
    def list_potholes(
        request: Request,
        conn: Conn,
        agency_id: str | None = None,
        status: Status | None = None,
        limit: Annotated[int, Query(ge=1, le=1000)] = 500,
    ) -> dict:
        where, params = [], []
        if agency_id:
            where.append("p.agency_id = ?")
            params.append(agency_id)
        if status:
            where.append("p.status = ?")
            params.append(status)
        clause = f"WHERE {' AND '.join(where)}" if where else ""
        rows = conn.execute(f"{POTHOLE_SQL} {clause} ORDER BY p.first_seen DESC LIMIT ?", (*params, limit)).fetchall()
        return {"potholes": [pothole_json(row, request) for row in rows]}

    @app.get("/potholes/{pothole_id}")
    def get_pothole(pothole_id: str, request: Request, conn: Conn) -> dict:
        pothole = pothole_json(load_pothole(conn, pothole_id), request)
        return {"pothole": pothole, "send_plan": send_plan_for(pothole)}

    @app.post("/potholes/{pothole_id}/send")
    def post_send(pothole_id: str, body: SendRequest, request: Request, conn: Conn) -> dict:
        row = load_pothole(conn, pothole_id)
        if row["agency_id"] is None:
            raise HTTPException(409, "No public agency owns this road")
        first = mark_sent(conn, pothole_id, row["agency_id"], body.method)
        return {"already_sent": not first, "pothole": pothole_json(load_pothole(conn, pothole_id), request)}

    @app.patch("/potholes/{pothole_id}/status", dependencies=[Depends(require_official)])
    def patch_status(pothole_id: str, body: StatusUpdate, request: Request, conn: Conn) -> dict:
        load_pothole(conn, pothole_id)
        changed_at = now_iso()
        with transaction(conn):
            conn.execute(
                "UPDATE potholes SET status = ?, updated_at = ?, fixed_at = ? WHERE id = ?",
                (body.status, changed_at, changed_at if body.status == "fixed" else None, pothole_id),
            )
            conn.execute(
                "INSERT INTO status_events (pothole_id, status, changed_at) VALUES (?, ?, ?)",
                (pothole_id, body.status, changed_at),
            )
        return {"pothole": pothole_json(load_pothole(conn, pothole_id), request)}

    @app.get("/queue", dependencies=[Depends(require_official)])
    def get_queue(request: Request, conn: Conn, agency_id: str | None = None) -> dict:
        sql = f"{POTHOLE_SQL} WHERE p.status != 'fixed' AND p.agency_id IS NOT NULL"
        params = ()
        if agency_id:
            sql += " AND p.agency_id = ?"
            params = (agency_id,)
        potholes = [pothole_json(row, request) for row in conn.execute(sql, params).fetchall()]
        potholes.sort(key=lambda p: (-p["priority"]["score"], p["first_seen"]))
        return {"potholes": potholes}

    @app.get("/agencies")
    def get_agencies() -> dict:
        return {"agencies": [
            {key: agency[key] for key in ("id", "name", "channel", "url", "phone", "email", "expected_response")}
            for agency in load_agencies()
        ]}

    @app.post("/officials/verify")
    def verify_official(body: VerifyRequest) -> dict:
        if limiter.locked():
            raise HTTPException(429, "Too many tries. Wait a minute.")
        if not settings.official_passcode:
            raise HTTPException(503, "Official sign-in is not set up")
        if not passcode_matches(body.passcode, settings.official_passcode):
            limiter.record_failure()
            raise HTTPException(401, "Wrong passcode")
        return {"verified": True, "token": official_token(settings.official_passcode, settings.reporter_secret)}

    return app


logging.basicConfig(level=logging.INFO, format="%(message)s")


def __getattr__(name: str):
    # Built on first use, so importing this module in tests needs no .env file.
    if name == "app":
        return create_app()
    raise AttributeError(name)
