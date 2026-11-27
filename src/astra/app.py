"""Astra terminal chat application."""

from __future__ import annotations

import asyncio
import sys
from typing import Any, ClassVar

from rich.markup import escape
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, VerticalScroll
from textual.widgets import Input, Static

from . import __version__
from .client import APIError, stream_chat
from .config import Config, load_config, save_config
from .credentials import key_status, resolve_key
from .settings import SettingsScreen
from .widgets import AssistantMessage, SystemNotice, UserMessage, Welcome


class AstraApp(App[None]):
    TITLE = "Astra"
    SUB_TITLE = "terminal chat"
    CSS_PATH = "app.tcss"

    BINDINGS: ClassVar[list[Binding]] = [
        Binding("ctrl+s", "settings", "设置"),
        Binding("ctrl+n", "new_chat", "新对话"),
        Binding("ctrl+t", "toggle_thinking", "思维链"),
        Binding("ctrl+y", "copy_last", "复制回复"),
        Binding("escape", "stop", "停止生成"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.config: Config = load_config()
        self.history: list[dict[str, str]] = []
        self._last_reply = ""
        self._busy = False
        self._worker: Any = None
        self._first_run_opened = False

    # ------------------------------------------------------------------ layout
    def compose(self) -> ComposeResult:
        with Horizontal(id="topbar"):
            yield Static(
                "[bold #7aa2f7]◈[/]  [bold #dce6ff]A S T R A[/]",
                id="brand",
                markup=True,
            )
            yield Static("", id="model-status", markup=True)
            yield Static("● 就绪", id="live-status", markup=True)
        yield VerticalScroll(Welcome(), id="chat")
        yield Input(placeholder="发消息给模型…", id="prompt")
        yield Static("", id="hint", markup=True)

    def on_mount(self) -> None:
        self._refresh_status()
        self._update_hint()
        self.query_one("#prompt", Input).focus()
        if not key_status(self.config.active_provider).exists:
            self.set_timer(0.35, self._open_first_run_settings)

    def _open_first_run_settings(self) -> None:
        if self._first_run_opened:
            return
        self._first_run_opened = True
        self.notify("先配置一个 API Key 就可以开始了。", timeout=5)
        self.push_screen(SettingsScreen(self.config), self._on_settings_closed)

    # -------------------------------------------------------------------- state
    @property
    def chat_log(self) -> VerticalScroll:
        return self.query_one("#chat", VerticalScroll)

    def _refresh_status(self) -> None:
        profile = self.config.provider
        status = key_status(self.config.active_provider)
        dot = "#9ece6a" if status.exists else "#e0af68"
        key_word = "KEY" if status.exists else "NO KEY"
        label = "anthropic" if self.config.active_provider == "anthropic" else "openai"
        self.query_one("#model-status", Static).update(
            f"[#565f89]{label}[/]  [#3b4261]·[/]  "
            f"[#c0caf5]{escape(profile.model)}[/]  [#3b4261]│[/]  "
            f"[{dot}]●[/] [#7b86a8]{key_word}[/]"
        )
        if not self._busy:
            self.query_one("#live-status", Static).update("[#9ece6a]● 就绪[/]")

    def _update_hint(self) -> None:
        if self._busy:
            text = (
                "[#e0af68]◌ 生成中[/]  [#3b4261]│[/]  "
                "[#9ece6a]Esc[/] [#7b86a8]停止生成[/]  [#3b4261]·[/]  "
                "[#565f89]Ctrl+N 新对话 · Ctrl+S 设置[/]"
            )
        else:
            parts = [
                "[#9ece6a]Enter[/] [#7b86a8]发送[/]",
                "[#9ece6a]Ctrl+S[/] [#7b86a8]设置[/]",
                "[#9ece6a]Ctrl+N[/] [#7b86a8]新对话[/]",
                "[#9ece6a]Ctrl+T[/] [#7b86a8]思维链[/]",
            ]
            if self.size.width >= 100:
                parts.append("[#9ece6a]Ctrl+Y[/] [#7b86a8]复制[/]")
            parts.append("[#9ece6a]Ctrl+Q[/] [#7b86a8]退出[/]")
            text = "  [#3b4261]·[/]  ".join(parts)
        self.query_one("#hint", Static).update(text)

    def on_resize(self, _event) -> None:
        try:
            self._update_hint()
        except Exception:
            pass

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        live = self.query_one("#live-status", Static)
        live.update(
            "[#e0af68]◌ 生成中[/]" if busy else "[#9ece6a]● 就绪[/]"
        )
        prompt = self.query_one("#prompt", Input)
        prompt.placeholder = (
            "生成中… Esc 停止" if busy else "发消息给模型…"
        )
        self._update_hint()

    async def _add_notice(self, message: str, severity: str = "info") -> None:
        icon = {"error": "✖", "success": "✔"}.get(severity, "ℹ")
        notice = SystemNotice(f"{icon}  {escape(message)}", severity)
        await self.chat_log.mount(notice)
        self.call_after_refresh(self._scroll_to_end)

    def _scroll_to_end(self) -> None:
        try:
            self.chat_log.scroll_end(animate=False, immediate=True)
        except Exception:
            pass

    async def _remove_welcome(self) -> None:
        for welcome in list(self.query(Welcome)):
            await welcome.remove()

    # ------------------------------------------------------------------ stream
    async def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id != "prompt":
            return
        await self._send(event.value)

    async def _send(self, value: str) -> None:
        text = value.strip()
        if not text:
            return
        if self._busy:
            self.notify("正在生成回复，按 Esc 停止后再发送。", severity="warning")
            return

        provider = self.config.active_provider
        api_key, _ = resolve_key(provider)
        if not api_key:
            self.notify(
                "还没有可用的 API Key，请先在设置中配置。", severity="error"
            )
            self.push_screen(
                SettingsScreen(self.config), self._on_settings_closed
            )
            return

        prompt = self.query_one("#prompt", Input)
        prompt.value = ""
        await self._remove_welcome()
        self.history.append({"role": "user", "content": text})

        profile = self.config.provider
        assistant = AssistantMessage(
            model_name=profile.model,
            show_thinking=self.config.show_thinking,
        )
        await self.chat_log.mount(UserMessage(text))
        await self.chat_log.mount(assistant)
        self._scroll_to_end()
        self._set_busy(True)
        prompt.focus()

        request_history = [dict(item) for item in self.history]
        snapshot = self.config.clone()
        self._worker = self.run_worker(
            self._stream_reply(
                assistant=assistant,
                messages=request_history,
                api_key=api_key,
                config=snapshot,
            ),
            name="astra",
            group="chat",
            exclusive=True,
            exit_on_error=False,
        )

    async def _stream_reply(
        self,
        *,
        assistant: AssistantMessage,
        messages: list[dict[str, str]],
        api_key: str,
        config: Config,
    ) -> None:
        profile = config.providers[config.active_provider]
        completed = False
        try:
            await stream_chat(
                provider=config.active_provider,
                base_url=profile.base_url,
                model=profile.model,
                api_key=api_key,
                messages=messages,
                system_prompt=config.system_prompt,
                max_tokens=config.max_tokens,
                temperature=config.temperature,
                request_thinking=config.request_thinking,
                on_text=assistant.append_text,
                on_thinking=assistant.append_thinking,
                on_notice=self._on_stream_notice,
            )
            completed = True
        except asyncio.CancelledError:
            assistant.finish(stopped=True)
        except APIError as exc:
            assistant.finish()
            await self._add_notice(exc.message, "error")
            if not assistant.has_content:
                await assistant.remove()
        except Exception as exc:  # defensive: never strand the UI
            assistant.finish()
            detail = str(exc).replace(api_key, "[REDACTED]")
            await self._add_notice(
                f"发生未预期错误：{type(exc).__name__}: {detail}", "error"
            )
            if not assistant.has_content:
                await assistant.remove()
        finally:
            if completed:
                assistant.finish()
                reply = assistant.text.strip()
                if reply:
                    self.history.append({"role": "assistant", "content": assistant.text})
                    self._last_reply = assistant.text
                elif not assistant.thinking.strip():
                    await assistant.remove()
            self._worker = None
            self._set_busy(False)
            try:
                self.query_one("#prompt", Input).focus()
            except Exception:
                pass

    async def _on_stream_notice(self, message: str) -> None:
        await self._add_notice(message, "info")

    # ----------------------------------------------------------------- actions
    def _on_settings_closed(self, config: Config | None) -> None:
        if config is not None:
            self.config = config
            for message in self.query(AssistantMessage):
                message.set_show_thinking(config.show_thinking)
            self.notify("设置已保存。", timeout=2)
        self._refresh_status()
        try:
            self.query_one("#prompt", Input).focus()
        except Exception:
            pass

    def _modal_open(self) -> bool:
        return len(self.screen_stack) > 1

    def action_settings(self) -> None:
        self._first_run_opened = True
        self.push_screen(SettingsScreen(self.config), self._on_settings_closed)

    def action_new_chat(self) -> None:
        if self._modal_open():
            return
        if self._busy and self._worker is not None:
            self._worker.cancel()
        self.history.clear()
        self._last_reply = ""
        chat = self.chat_log
        for child in list(chat.children):
            child.remove()
        self.call_after_refresh(lambda: chat.mount(Welcome()))
        self.notify("开始新对话。", timeout=2)

    def action_toggle_thinking(self) -> None:
        if self._modal_open():
            return
        self.config.show_thinking = not self.config.show_thinking
        for message in self.query(AssistantMessage):
            message.set_show_thinking(self.config.show_thinking)
        try:
            save_config(self.config)
        except OSError:
            pass
        state = "显示" if self.config.show_thinking else "隐藏"
        self.notify(f"思维链：{state}", timeout=2)

    def action_copy_last(self) -> None:
        if self._modal_open():
            return
        if not self._last_reply:
            self.notify("还没有可复制的回复。", severity="information")
            return
        try:
            self.copy_to_clipboard(self._last_reply)
            self.notify("回复已复制到剪贴板。", timeout=2)
        except Exception:
            self.notify("剪贴板不可用，复制失败。", severity="warning")

    def action_stop(self) -> None:
        if self._busy and self._worker is not None:
            self._worker.cancel()
            self.query_one("#live-status", Static).update(
                "[#e0af68]◌ 正在停止…[/]"
            )


def main() -> None:
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg in ("--version", "-V"):
            print(f"astra {__version__}")
            return
        if arg in ("--help", "-h"):
            print(
                "Astra - terminal AI chat\n\n"
                "Usage:\n"
                "  astra            start the TUI\n"
                "  astra --version  show version\n"
                "  astra --help     show this help\n\n"
                "Settings open automatically on first run.\n"
                "Keys: Ctrl+S settings | Ctrl+N new chat | Ctrl+T reasoning | Ctrl+Q quit"
            )
            return
        print(f"Unknown argument: {arg} (try: astra --help)", file=sys.stderr)
        raise SystemExit(2)
    AstraApp().run()


if __name__ == "__main__":
    main()
