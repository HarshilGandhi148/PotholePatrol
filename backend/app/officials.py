"""One shared officials passcode. Real accounts wait for MVP 2.

POST /officials/verify swaps the passcode for a token, so the app stores the token
in the Keychain instead of the passcode. Without a passcode set, nobody gets in.
"""

from __future__ import annotations

import hashlib
import hmac
import time
from collections import deque

MAX_FAILURES = 10
WINDOW_SECONDS = 60


def official_token(passcode: str, secret: str) -> str:
    return hmac.new(secret.encode(), f"official:{passcode}".encode(), hashlib.sha256).hexdigest()


def passcode_matches(given: str, passcode: str) -> bool:
    return bool(passcode) and hmac.compare_digest(given.encode(), passcode.encode())


def token_matches(given: str | None, passcode: str, secret: str) -> bool:
    if not given or not passcode:
        return False
    return hmac.compare_digest(given.encode(), official_token(passcode, secret).encode())


class FailureLimiter:
    """Slows down passcode guessing: 10 wrong tries a minute, across all callers."""

    def __init__(self) -> None:
        self._failures: deque[float] = deque()

    def _trim(self) -> None:
        cutoff = time.monotonic() - WINDOW_SECONDS
        while self._failures and self._failures[0] < cutoff:
            self._failures.popleft()

    def locked(self) -> bool:
        self._trim()
        return len(self._failures) >= MAX_FAILURES

    def record_failure(self) -> None:
        self._failures.append(time.monotonic())
