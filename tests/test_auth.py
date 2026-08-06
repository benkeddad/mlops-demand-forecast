from unittest.mock import patch

from app.auth import require_api_key
from fastapi import HTTPException
import pytest


def test_require_api_key_allows_all_when_unset():
    with patch("app.auth.API_KEY", None):
        # Should not raise regardless of header value.
        require_api_key(x_api_key=None)
        require_api_key(x_api_key="anything")


def test_require_api_key_rejects_missing_or_wrong_key_when_set():
    with patch("app.auth.API_KEY", "secret123"):
        with pytest.raises(HTTPException) as exc:
            require_api_key(x_api_key=None)
        assert exc.value.status_code == 401

        with pytest.raises(HTTPException):
            require_api_key(x_api_key="wrong")


def test_require_api_key_accepts_matching_key_when_set():
    with patch("app.auth.API_KEY", "secret123"):
        # Should not raise.
        require_api_key(x_api_key="secret123")
