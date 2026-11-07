"""Shared test setup: a real API on the synthetic map, with a throwaway database."""

import io
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app
from app.map_data import MapData

FIXTURE = Path(__file__).parent / "fixtures" / "mini_city"

PASSCODE = "test-passcode"


@pytest.fixture(scope="session")
def map_data() -> MapData:
    return MapData.from_dir(FIXTURE)


def make_settings(tmp_path, **overrides) -> Settings:
    values = dict(
        data_dir=FIXTURE,
        db_path=tmp_path / "test.db",
        photo_dir=tmp_path / "photos",
        public_base_url="https://api.test",
        official_passcode=PASSCODE,
        reporter_secret="test-secret",
        send_threshold=1,
    )
    return Settings(**{**values, **overrides})


@pytest.fixture
def client(tmp_path, map_data):
    with TestClient(create_app(make_settings(tmp_path), map_data)) as test_client:
        yield test_client


@pytest.fixture
def jpeg() -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (40, 30), "gray").save(out, format="JPEG")
    return out.getvalue()


@pytest.fixture
def detect(client, jpeg):
    """POST a detection on Main Street, unless told otherwise."""

    def _detect(lat=40.4201, lng=-86.8800, device_id="device-0001", captured_at="2026-11-07T15:00:00Z"):
        return client.post(
            "/detections",
            data={"lat": lat, "lng": lng, "captured_at": captured_at, "device_id": device_id},
            files={"photo": ("p.jpg", jpeg, "image/jpeg")},
        )

    return _detect


@pytest.fixture
def official_headers(client):
    token = client.post("/officials/verify", json={"passcode": PASSCODE}).json()["token"]
    return {"X-Official-Token": token}
