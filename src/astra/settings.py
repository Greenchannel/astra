"""Settings modal: provider, endpoint, model, system prompt, and API key."""

from __future__ import annotations

from typing import ClassVar
from urllib.parse import urlparse

from rich.markup import escape
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Input, Select, Static, TextArea

from .config import (
    PROVIDER_LABELS,
    PROVIDERS,
    Config,
    Profile,
    config_path,
    save_config,
)
from .credentials import CredentialError, delete_key, key_status, set_key


class SettingsScreen(ModalScreen[Config | None]):
    BINDINGS: ClassVar[list[tuple[str, str, str]]] = [
        ("escape", "cancel", "取消"),
        ("ctrl+s", "save", "保存"),
    ]

    def __init__(self, config: Config) -> None:
        super().__init__()
        self.config = config.clone()

    # ----------------------------------------------------------------- compose
    def compose(self) -> ComposeResult:
        current = self.config.active_provider
        profile = self.config.providers[current]
        with Vertical(id="settings-panel"):
            yield Static("◇  设置", id="settings-title")
            yield Static(
                "[#565f89]API Key 保存在系统凭据管理器，不写入配置文件。[/]",
                id="settings-subtitle",
                markup=True,
            )
            with VerticalScroll(id="settings-body"):
                yield Static("接口格式", classes="field-label")
                yield Select(
                    [
                        (PROVIDER_LABELS[provider], provider)
                        for provider in PROVIDERS
                    ],
                    id="provider",
                    allow_blank=False,
                    value=current,
                )
                yield Static("API Key", classes="field-label")
                yield Static("", id="key-status", markup=True)
                with Horizontal(id="key-row"):
                    yield Input(
                        value="",
                        password=True,
                        id="key-input",
                        placeholder="粘贴 API Key",
                    )
                    yield Button(
                        "清除已保存 Key",
                        id="clear-key",
                        compact=True,
                        flat=True,
                    )
                yield Static("Base URL", classes="field-label")
                yield Input(
                    value=profile.base_url,
                    id="base-url",
                    placeholder="https://api.openai.com/v1",
                )
                yield Static("模型", classes="field-label")
                yield Input(
                    value=profile.model,
                    id="model",
                    placeholder="gpt-4o-mini / claude-opus-5",
                )
                yield Static("默认提示词（可留空）", classes="field-label")
                yield TextArea(
                    self.config.system_prompt,
                    id="system-prompt",
                    placeholder="留空则不发送 system prompt",
                )
                yield Static("行为", classes="field-label")
                yield Checkbox(
                    "在对话中显示思维链",
                    value=self.config.show_thinking,
                    id="show-thinking",
                )
                yield Checkbox(
                    "请求思维链（Anthropic adaptive thinking）",
                    value=self.config.request_thinking,
                    id="request-thinking",
                )
                with Horizontal(classes="field-row"):
                    with Vertical(classes="field-col"):
                        yield Static("最大输出 tokens", classes="field-label")
                        yield Input(
                            value=str(self.config.max_tokens),
                            id="max-tokens",
                            type="integer",
                        )
                    with Vertical(classes="field-col"):
                        yield Static("温度（仅 OpenAI，留空不发送）", classes="field-label")
                        yield Input(
                            value=(
                                ""
                                if self.config.temperature is None
                                else f"{self.config.temperature:g}"
                            ),
                            id="temperature",
                            type="number",
                        )
            yield Static("", id="settings-error", markup=True)
            with Horizontal(id="settings-actions"):
                yield Button("保存  Ctrl+S", variant="primary", id="save")
                yield Button("取消  Esc", id="cancel")
            yield Static(
                f"[#565f89]配置文件：{escape(str(config_path()))}[/]",
                id="settings-footnote",
                markup=True,
            )

    def on_mount(self) -> None:
        self._refresh_key_status(self.config.active_provider)
        self.query_one("#provider", Select).focus()

    # ------------------------------------------------------------------- state
    def _selected_provider(self) -> str:
        value = self.query_one("#provider", Select).value
        return value if isinstance(value, str) and value in PROVIDERS else "openai"

    def _refresh_key_status(self, provider: str) -> None:
        status = key_status(provider)
        if status.exists:
            text = (
                "[#9ece6a]● 已配置[/]  "
                f"[#7b86a8]{escape(status.source)}[/]"
            )
            if status.from_env:
                text += "[#565f89]  · 环境变量优先[/]"
            self.query_one("#key-input", Input).placeholder = (
                "已配置 — 留空保持不变，输入新 Key 覆盖"
            )
        else:
            text = (
                "[#e0af68]● 未配置[/]  "
                f"[#7b86a8]{escape(status.source)}[/]"
            )
            self.query_one("#key-input", Input).placeholder = (
                "粘贴 API Key（保存到系统凭据管理器）"
            )
        self.query_one("#key-status", Static).update(text)

    def _show_error(self, message: str = "") -> None:
        error = self.query_one("#settings-error", Static)
        error.display = bool(message)
        error.update(f"[#f7768e]{escape(message)}[/]" if message else "")

    # ------------------------------------------------------------------ events
    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id != "provider":
            return
        provider = event.value
        if not isinstance(provider, str) or provider not in PROVIDERS:
            return
        profile = self.config.providers[provider]
        self.query_one("#base-url", Input).value = profile.base_url
        self.query_one("#model", Input).value = profile.model
        self.query_one("#key-input", Input).value = ""
        self._refresh_key_status(provider)
        self._show_error("")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "save":
            self.action_save()
        elif event.button.id == "cancel":
            self.action_cancel()
        elif event.button.id == "clear-key":
            provider = self._selected_provider()
            try:
                delete_key(provider)
            except CredentialError as exc:
                self._show_error(str(exc))
                return
            self._refresh_key_status(provider)
            self._show_error("")
            self.notify("已清除保存在凭据管理器中的 Key。", severity="information")

    # ----------------------------------------------------------------- actions
    def action_cancel(self) -> None:
        self.dismiss(None)

    def action_save(self) -> None:
        provider = self._selected_provider()
        base_url = self.query_one("#base-url", Input).value.strip()
        model = self.query_one("#model", Input).value.strip()
        new_key = self.query_one("#key-input", Input).value.strip()
        system_prompt = self.query_one("#system-prompt", TextArea).text
        show_thinking = self.query_one("#show-thinking", Checkbox).value
        request_thinking = self.query_one("#request-thinking", Checkbox).value

        parsed = urlparse(base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            self._show_error("Base URL 必须是完整的 http(s) 地址。")
            return
        if not model:
            self._show_error("模型名不能为空。")
            return

        try:
            max_tokens = int(self.query_one("#max-tokens", Input).value.strip())
        except ValueError:
            self._show_error("最大 tokens 必须是整数。")
            return
        if not 1 <= max_tokens <= 200_000:
            self._show_error("最大 tokens 需在 1 到 200000 之间。")
            return
        temperature_text = self.query_one("#temperature", Input).value.strip()
        if temperature_text:
            try:
                temperature: float | None = float(temperature_text)
            except ValueError:
                self._show_error("温度必须是数字，或留空。")
                return
            if not 0.0 <= temperature <= 2.0:
                self._show_error("温度需在 0 到 2 之间。")
                return
        else:
            temperature = None

        if new_key:
            try:
                set_key(provider, new_key)
            except CredentialError as exc:
                self._show_error(str(exc))
                return

        updated = self.config.clone()
        updated.active_provider = provider
        updated.providers[provider] = Profile(base_url=base_url, model=model)
        updated.system_prompt = system_prompt
        updated.show_thinking = show_thinking
        updated.request_thinking = request_thinking
        updated.max_tokens = max_tokens
        updated.temperature = temperature
        try:
            save_config(updated)
        except OSError as exc:
            self._show_error(f"无法保存配置文件：{exc}")
            return
        self.dismiss(updated)
