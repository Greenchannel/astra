from __future__ import annotations

import asyncio
import json

import pytest
from textual.widgets import Collapsible, Input, TextArea

import astra.app as app_module
import astra.settings as settings_module
from astra.app import AstraApp
from astra.config import load_config, save_config
from astra.credentials import KeyStatus
from astra.settings import SettingsScreen
from astra.widgets import AssistantMessage, Welcome


@pytest.fixture()
def app_env(tmp_path, monkeypatch):
    monkeypatch.setenv("ASTRA_CONFIG_DIR", str(tmp_path / "config"))
    monkeypatch.setenv("ASTRA_API_KEY", "test-key")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    return tmp_path


async def wait_idle(app: AstraApp, pilot, timeout: float = 3.0) -> None:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while app._busy:
        if loop.time() > deadline:
            raise AssertionError("app stayed busy")
        await pilot.pause(0.02)


async def test_streaming_message_and_thinking_toggle(app_env, monkeypatch) -> None:
    async def fake_stream(**kwargs):
        kwargs["on_thinking"]("先想一下")
        await asyncio.sleep(0)
        kwargs["on_text"]("答")
        kwargs["on_text"]("案")
        await asyncio.sleep(0.01)

    monkeypatch.setattr(app_module, "stream_chat", fake_stream)
    app = AstraApp()
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        prompt = app.query_one("#prompt", Input)
        prompt.value = "你好"
        await pilot.press("enter")
        await wait_idle(app, pilot)

        assistant = app.query_one(AssistantMessage)
        assert assistant.text == "答案"
        assert assistant.thinking == "先想一下"
        assert assistant.query_one(Collapsible).display is True
        assert app.history == [
            {"role": "user", "content": "你好"},
            {"role": "assistant", "content": "答案"},
        ]
        assert app._last_reply == "答案"

        await pilot.press("ctrl+t")
        await pilot.pause()
        assert app.config.show_thinking is False
        assert assistant.query_one(Collapsible).display is False

        await pilot.press("ctrl+t")
        await pilot.pause()
        assert app.config.show_thinking is True
        assert assistant.query_one(Collapsible).display is True

        await pilot.press("ctrl+n")
        await pilot.pause()
        assert app.history == []
        assert list(app.query(AssistantMessage)) == []
        assert list(app.query(Welcome))


async def test_escape_stops_generation(app_env, monkeypatch) -> None:
    started = asyncio.Event()

    async def slow_stream(**kwargs):
        kwargs["on_text"]("部分")
        started.set()
        await asyncio.sleep(30)

    monkeypatch.setattr(app_module, "stream_chat", slow_stream)
    app = AstraApp()
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause()
        app.query_one("#prompt", Input).value = "继续"
        await pilot.press("enter")
        await asyncio.wait_for(started.wait(), timeout=2)
        await pilot.press("escape")
        await wait_idle(app, pilot)

        assistant = app.query_one(AssistantMessage)
        assert assistant.text == "部分"
        assert "已停止" in str(assistant._status.render())
        assert app.history == [{"role": "user", "content": "继续"}]


async def test_settings_can_clear_system_prompt(app_env, monkeypatch) -> None:
    cfg = load_config()
    cfg.system_prompt = "old prompt"
    save_config(cfg)

    app = AstraApp()
    async with app.run_test(size=(110, 40)) as pilot:
        await pilot.pause()
        await pilot.press("ctrl+s")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, SettingsScreen)
        assert screen.query_one("#base-url", Input).value == (
            "https://api.anthropic.com"
        )

        area = screen.query_one("#system-prompt", TextArea)
        assert area.text == "old prompt"
        area.text = ""
        await pilot.press("ctrl+s")
        await pilot.pause()

        assert app.screen is not screen
        assert app.config.system_prompt == ""
        assert load_config().system_prompt == ""

        raw = json.loads(
            (app_env / "config" / "config.json").read_text(encoding="utf-8")
        )
        assert "api_key" not in json.dumps(raw).lower()


async def test_first_run_opens_settings(app_env, monkeypatch) -> None:
    monkeypatch.delenv("ASTRA_API_KEY", raising=False)
    no_key = KeyStatus(False, "未配置")
    monkeypatch.setattr(app_module, "key_status", lambda provider: no_key)
    monkeypatch.setattr(settings_module, "key_status", lambda provider: no_key)

    app = AstraApp()
    async with app.run_test(size=(100, 32)) as pilot:
        await pilot.pause(0.6)
        assert isinstance(app.screen, SettingsScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, SettingsScreen)
