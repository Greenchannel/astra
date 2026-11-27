from __future__ import annotations

import json

import pytest

from astra import credentials
from astra.config import Config, Profile, load_config, save_config


@pytest.fixture()
def config_home(tmp_path, monkeypatch):
    monkeypatch.setenv("ASTRA_CONFIG_DIR", str(tmp_path / "config"))
    return tmp_path / "config"


def test_defaults_and_roundtrip(config_home, monkeypatch) -> None:
    monkeypatch.setenv("ASTRA_CONFIG_DIR", str(config_home))
    cfg = load_config()
    assert cfg.active_provider == "anthropic"
    assert cfg.system_prompt == ""
    assert cfg.providers["anthropic"].model == "claude-opus-5"

    cfg.providers["openai"] = Profile("https://example.test/v1", "my-model")
    cfg.active_provider = "openai"
    cfg.system_prompt = ""
    cfg.max_tokens = 1024
    cfg.temperature = 0.2
    path = save_config(cfg)
    assert path == config_home / "config.json"

    raw = json.loads(path.read_text(encoding="utf-8"))
    assert "api_key" not in json.dumps(raw).lower()
    assert raw["system_prompt"] == ""

    loaded = load_config()
    assert loaded.active_provider == "openai"
    assert loaded.providers["openai"].model == "my-model"
    assert loaded.system_prompt == ""
    assert loaded.max_tokens == 1024
    assert loaded.temperature == pytest.approx(0.2)


def test_malformed_config_falls_back(config_home, monkeypatch) -> None:
    monkeypatch.setenv("ASTRA_CONFIG_DIR", str(config_home))
    config_home.mkdir(parents=True, exist_ok=True)
    (config_home / "config.json").write_text("{not json", encoding="utf-8")
    cfg = load_config()
    assert isinstance(cfg, Config)
    assert cfg.providers["anthropic"].base_url == "https://api.anthropic.com"


def test_env_key_takes_precedence(monkeypatch) -> None:
    monkeypatch.setenv("ASTRA_API_KEY", "env-secret")
    monkeypatch.setenv("OPENAI_API_KEY", "provider-secret")

    def boom(*args, **kwargs):
        raise AssertionError("keyring must not be consulted when env is set")

    monkeypatch.setattr(credentials.keyring, "get_password", boom)
    key, status = credentials.resolve_key("openai")
    assert key == "env-secret"
    assert status.exists is True
    assert status.from_env is True
    assert "ASTRA_API_KEY" in status.source


def test_stored_key_is_read_from_keyring(monkeypatch) -> None:
    monkeypatch.delenv("ASTRA_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setattr(
        credentials.keyring,
        "get_password",
        lambda service, account: "stored-secret"
        if service == credentials.SERVICE_NAME
        and account == "api-key:anthropic"
        else None,
    )
    key, status = credentials.resolve_key("anthropic")
    assert key == "stored-secret"
    assert status.exists is True
    assert status.from_env is False


def test_set_and_delete_key_use_keyring(monkeypatch) -> None:
    calls: dict = {}

    def fake_set(service, account, value):
        calls["set"] = (service, account, value)

    def fake_delete(service, account):
        calls["delete"] = (service, account)

    monkeypatch.setattr(credentials.keyring, "set_password", fake_set)
    monkeypatch.setattr(credentials.keyring, "delete_password", fake_delete)

    credentials.set_key("openai", "  abc  ")
    assert calls["set"] == (
        credentials.SERVICE_NAME,
        "api-key:openai",
        "abc",
    )
    credentials.delete_key("openai")
    assert calls["delete"] == (credentials.SERVICE_NAME, "api-key:openai")
