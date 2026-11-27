"""Chat message widgets."""

from __future__ import annotations

import time

from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.timer import Timer
from textual.widgets import Collapsible, Markdown, Static

WELCOME_TEXT = (
    "[bold #7aa2f7]◈[/]  [bold #dce6ff]A S T R A[/]\n"
    "[#565f89]terminal chat · OpenAI / Anthropic[/]\n\n"
    "[#3b4261]──────────────────────────────[/]\n\n"
    "[#9ece6a]Enter[/]    [#7b86a8]发送消息[/]\n"
    "[#9ece6a]Ctrl+S[/]   [#7b86a8]配置模型与 API Key[/]\n"
    "[#9ece6a]Ctrl+T[/]   [#7b86a8]显示 / 隐藏思维链[/]\n"
    "[#9ece6a]Ctrl+N[/]   [#7b86a8]开始新对话[/]"
)


class Welcome(Vertical):
    def __init__(self) -> None:
        super().__init__(id="welcome", classes="welcome-wrap")

    def compose(self) -> ComposeResult:
        yield Static(WELCOME_TEXT, classes="welcome-card", markup=True)

    def on_mount(self) -> None:
        self.call_after_refresh(self.scroll_visible)


class UserMessage(Vertical):
    def __init__(self, text: str) -> None:
        super().__init__(classes="message user-message")
        self.text = text

    def compose(self) -> ComposeResult:
        with Vertical(classes="user-bubble"):
            yield Static("YOU", classes="role user-role")
            yield Markdown(self.text, classes="user-text")


class AssistantMessage(Vertical):
    """A streaming assistant turn with an optional reasoning panel."""

    def __init__(self, model_name: str, show_thinking: bool = True) -> None:
        super().__init__(classes="message assistant-message")
        self.model_name = model_name
        self.text = ""
        self.thinking = ""
        self._show_thinking = show_thinking
        self._started = time.monotonic()
        self._finished_at: float | None = None
        self._streaming = True
        self._dirty_text = False
        self._dirty_thinking = False
        self._phase = "connecting"
        self._timer: Timer | None = None

        self._status = Static("正在连接…", classes="msg-status")
        self._reasoning_body = Markdown("", classes="reasoning-text")
        self._reasoning = Collapsible(
            self._reasoning_body,
            title="思维链",
            collapsed=False,
            classes="reasoning",
        )
        self._body = Markdown("", classes="answer")
        self._cursor = Static("▍", classes="stream-cursor")

    def compose(self) -> ComposeResult:
        with Horizontal(classes="msg-head"):
            yield Static("◈ 助手", classes="role assistant-role")
            yield Static(self.model_name, classes="msg-model", markup=False)
            yield self._status
        yield self._reasoning
        with Vertical(classes="assistant-bubble"):
            yield self._body
            yield self._cursor

    def on_mount(self) -> None:
        self._reasoning.display = False
        self._timer = self.set_interval(0.07, self._flush)

    @property
    def has_content(self) -> bool:
        return bool(self.text.strip() or self.thinking.strip())

    @property
    def elapsed(self) -> float:
        end = self._finished_at if self._finished_at is not None else time.monotonic()
        return max(0.0, end - self._started)

    def append_text(self, chunk: str) -> None:
        if not chunk:
            return
        self.text += chunk
        self._dirty_text = True
        if self._phase != "answering":
            self._phase = "answering"
            self._status.update("生成中…")

    def append_thinking(self, chunk: str) -> None:
        if not chunk:
            return
        if self._phase in ("connecting", "thinking"):
            self._phase = "thinking"
            self._status.update("思考中…")
        self.thinking += chunk
        self._dirty_thinking = True
        if self._show_thinking:
            self._reasoning.display = True

    def set_show_thinking(self, show: bool) -> None:
        self._show_thinking = show
        self._reasoning.display = bool(show and self.thinking)

    def _flush(self) -> None:
        try:
            chat = self.app.query_one("#chat", VerticalScroll)
            at_end = chat.is_vertical_scroll_end
        except Exception:
            at_end = True
        if self._dirty_text:
            self._body.update(self.text)
            self._dirty_text = False
        if self._dirty_thinking:
            self._reasoning_body.update(self.thinking)
            self._reasoning.title = f"思维链 · {len(self.thinking)} 字"
            if self._show_thinking:
                self._reasoning.display = True
            self._dirty_thinking = False
        if at_end:
            self.call_after_refresh(self._scroll_end)

    def _scroll_end(self) -> None:
        try:
            self.app.query_one("#chat", VerticalScroll).scroll_end(
                animate=False, immediate=True
            )
        except Exception:
            pass

    def finish(self, stopped: bool = False) -> None:
        if not self._streaming:
            return
        try:
            chat = self.app.query_one("#chat", VerticalScroll)
            at_end = chat.is_vertical_scroll_end
        except Exception:
            at_end = True
        self._streaming = False
        self._finished_at = time.monotonic()
        self._flush()
        self._cursor.display = False
        if self._timer:
            self._timer.stop()
            self._timer = None
        if self.thinking:
            self._reasoning.title = f"思维链 · {len(self.thinking)} 字"
            self._reasoning.display = self._show_thinking
        else:
            self._reasoning.display = False
        duration = f"{self.elapsed:.1f}s"
        self._status.update(f"已停止 · {duration}" if stopped else duration)
        if stopped and not self.text.strip():
            self._body.update("*（已停止）*")
        if at_end:
            self.call_after_refresh(self._scroll_end)


class SystemNotice(Static):
    def __init__(self, text: str, severity: str = "info") -> None:
        super().__init__(
            text,
            classes=f"notice notice-{severity}",
            markup=True,
        )
