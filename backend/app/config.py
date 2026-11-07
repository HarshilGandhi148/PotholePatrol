"""Settings, read from backend/.env or the environment."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    db_path: Path
    photo_dir: Path
    public_base_url: str          # the HTTPS address the phone uses
    official_passcode: str
    reporter_secret: str
    send_threshold: int = 3       # distinct devices before we ask someone to report
    max_photo_bytes: int = 10_000_000

    @classmethod
    def from_env(cls) -> "Settings":
        load_dotenv(BACKEND_DIR / ".env")
        secret = os.environ.get("REPORTER_SECRET", "")
        if not secret:
            raise RuntimeError("Set REPORTER_SECRET in backend/.env (see .env.example)")
        storage = Path(os.environ.get("STORAGE_DIR", BACKEND_DIR / "storage"))
        return cls(
            data_dir=Path(os.environ.get("MAP_DATA_DIR", BACKEND_DIR / "data")),
            db_path=storage / "potholepatrol.db",
            photo_dir=storage / "photos",
            public_base_url=os.environ.get("PUBLIC_BASE_URL", "").rstrip("/"),
            official_passcode=os.environ.get("OFFICIAL_PASSCODE", ""),
            reporter_secret=secret,
            send_threshold=int(os.environ.get("SEND_THRESHOLD", "3")),
        )
