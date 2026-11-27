"""Configuration for Astra.

The config file deliberately contains **no credentials**. API keys live in the
OS credential store (Windows Credential Manager via keyring) or environment
variables — see :mod:`astra.credentials`.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

PROVIDERS = ("anthropic", "openai")

PROVIDER_LABELS = {
    "anthropic": "Anthropic /v1/messages",
    "openai": "OpenAI 兼容 /chat/completions",
}

DEFAULT_PROFILES: dict[str, dict[str, str]] = {
    "anthropic": {
        "base_url": "https://api.anthropic.com",
        "model": "claude-opus-5",
    },
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
    },
}


@dataclass
class Profile:
    base_url: str
    model: str


@dataclass
class Config:
    active_provider: str = "anthropic"
    providers: dict[str, Profile] = field(
        default_factory=lambda: {
            key: Profile(**values) for key, values in DEFAULT_PROFILES.items()
        }
    )
    system_prompt: str = ""
    show_thinking: bool = True
    request_thinking: bool = True
    max_tokens: int = 8192
    # Only sent to OpenAI-compatible endpoints; current Claude models reject it.
    # None means "omit the parameter" for models that reject sampling params.
    temperature: float | None = 0.7

    @property
    def provider(self) -> Profile:
        return self.providers[self.active_provider]

    def clone(self) -> Config:
        return Config(
            active_provider=self.active_provider,
            providers={
                key: Profile(base_url=p.base_url, model=p.model)
                for key, p in self.providers.items()
            },
            system_prompt=self.system_prompt,
            show_thinking=self.show_thinking,
            request_thinking=self.request_thinking,
            max_tokens=self.max_tokens,
            temperature=self.temperature,
        )


def config_dir() -> Path:
    """Return the config directory (overridable with ``ASTRA_CONFIG_DIR``).

    When running from a source checkout, settings live in the project's
    ``.state`` directory so the app stays self-contained. Installed builds fall
    back to the platform config directory.
    """
    override = os.environ.get("ASTRA_CONFIG_DIR")
    if override:
        return Path(override).expanduser()
    project_root = Path(__file__).resolve().parents[2]
    if (project_root / "pyproject.toml").is_file():
        return project_root / ".state"
    if sys.platform == "win32" and os.environ.get("APPDATA"):
        return Path(os.environ["APPDATA"]) / "astra"
    base = os.environ.get("XDG_CONFIG_HOME")
    return (Path(base) if base else Path.home() / ".config") / "astra"


def config_path() -> Path:
    return config_dir() / "config.json"


def _coerce_profiles(raw: Any) -> dict[str, Profile]:
    profiles = {key: Profile(**values) for key, values in DEFAULT_PROFILES.items()}
    if not isinstance(raw, dict):
        return profiles
    for key in PROVIDERS:
        item = raw.get(key)
        if not isinstance(item, dict):
            continue
        base_url = item.get("base_url")
        model = item.get("model")
        if isinstance(base_url, str) and base_url.strip():
            profiles[key].base_url = base_url.strip()
        if isinstance(model, str) and model.strip():
            profiles[key].model = model.strip()
    return profiles


def _coerce_bool(value: Any, default: bool) -> bool:
    return value if isinstance(value, bool) else default


def _coerce_number(value: Any, default, cast):
    try:
        if isinstance(value, bool):
            return default
        return cast(value)
    except (TypeError, ValueError):
        return default


def load_config() -> Config:
    """Load config, falling back to defaults if missing or malformed."""
    path = config_path()
    defaults = Config()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return defaults
    if not isinstance(raw, dict):
        return defaults

    active = raw.get("active_provider")
    if active not in PROVIDERS:
        active = defaults.active_provider

    max_tokens = _coerce_number(raw.get("max_tokens"), defaults.max_tokens, int)
    if not 1 <= max_tokens <= 200_000:
        max_tokens = defaults.max_tokens
    raw_temperature = raw.get("temperature", defaults.temperature)
    if raw_temperature is None:
        temperature = None
    else:
        temperature = _coerce_number(raw_temperature, defaults.temperature, float)
        temperature = min(2.0, max(0.0, temperature))

    system_prompt = raw.get("system_prompt")
    if not isinstance(system_prompt, str):
        system_prompt = ""

    return Config(
        active_provider=active,
        providers=_coerce_profiles(raw.get("providers")),
        system_prompt=system_prompt,
        show_thinking=_coerce_bool(raw.get("show_thinking"), defaults.show_thinking),
        request_thinking=_coerce_bool(
            raw.get("request_thinking"), defaults.request_thinking
        ),
        max_tokens=max_tokens,
        temperature=temperature,
    )


def save_config(config: Config) -> Path:
    """Persist config atomically. Credentials are never written here."""
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = asdict(config)
    fd, tmp_name = tempfile.mkstemp(
        prefix=".config-", suffix=".json", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    try:
        if os.name != "nt":
            os.chmod(path, 0o600)
    except OSError:
        pass
    return path
