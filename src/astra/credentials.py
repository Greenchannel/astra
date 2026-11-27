"""Secure API-key storage.

Resolution order:

1. ``ASTRA_API_KEY`` / provider-specific environment variables
2. The operating system credential store (Windows Credential Manager, macOS
   Keychain, Secret Service on Linux) through ``keyring``

There is intentionally **no plaintext fallback**. If the credential store is
unavailable, the app tells the user to use an environment variable.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass

import keyring

SERVICE_NAME = "astra-tui"

ENV_VARS = {
    "openai": ("ASTRA_API_KEY", "OPENAI_API_KEY"),
    "anthropic": ("ASTRA_API_KEY", "ANTHROPIC_API_KEY"),
}


class CredentialError(RuntimeError):
    """Raised when a credential cannot be stored or read."""


@dataclass(frozen=True)
class KeyStatus:
    exists: bool
    source: str  # human readable, safe to show
    from_env: bool = False


def _account(provider: str) -> str:
    return f"api-key:{provider}"


def _env_lookup(provider: str) -> tuple[str | None, str | None]:
    for name in ENV_VARS.get(provider, ()):
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip(), name
    return None, None


def resolve_key(provider: str) -> tuple[str | None, KeyStatus]:
    """Return ``(key, status)`` without ever exposing the key to the UI."""
    value, env_name = _env_lookup(provider)
    if value:
        return value, KeyStatus(True, f"环境变量 {env_name}", from_env=True)
    try:
        stored = keyring.get_password(SERVICE_NAME, _account(provider))
    except Exception:
        return None, KeyStatus(
            False,
            "凭据管理器不可用（可用环境变量 "
            + ("ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY")
            + "）",
        )
    if stored:
        label = "Windows 凭据管理器" if sys.platform == "win32" else "系统凭据管理器"
        return stored, KeyStatus(True, label)
    return None, KeyStatus(False, "未配置")


def key_status(provider: str) -> KeyStatus:
    return resolve_key(provider)[1]


def set_key(provider: str, key: str) -> None:
    """Store a key in the OS credential store. Never writes it to disk here."""
    key = key.strip()
    if not key:
        raise CredentialError("API Key 不能为空。")
    try:
        keyring.set_password(SERVICE_NAME, _account(provider), key)
    except Exception as exc:  # backend-specific exceptions vary by platform
        raise CredentialError(
            "无法写入系统凭据管理器。请改用环境变量 "
            + ("ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY")
            + "，或检查系统凭据服务。"
        ) from exc


def delete_key(provider: str) -> None:
    """Remove the stored key (environment-variable keys are unaffected)."""
    try:
        keyring.delete_password(SERVICE_NAME, _account(provider))
    except keyring.errors.PasswordDeleteError:
        return
    except Exception as exc:
        raise CredentialError("无法从系统凭据管理器删除该 Key。") from exc
