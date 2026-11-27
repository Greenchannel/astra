"""Streaming clients for OpenAI-compatible and Anthropic APIs.

OpenAI-compatible endpoints are spoken to via raw SSE because every gateway has
its own dialect. Anthropic goes through the official ``anthropic`` SDK.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import re
from collections.abc import AsyncIterator, Callable, Sequence
from typing import Any

import anthropic
import httpx

TextCallback = Callable[[str], Any]
NoticeCallback = Callable[[str], Any]


class APIError(RuntimeError):
    def __init__(self, status: int | None, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def _scrub(text: str, api_key: str) -> str:
    if api_key and api_key in text:
        text = text.replace(api_key, "[REDACTED]")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    return text[:900]


async def _emit(callback: Callable[[str], Any] | None, text: str) -> None:
    """Support both sync and async callbacks."""
    if callback is None:
        return
    result = callback(text)
    if inspect.isawaitable(result):
        await result


def friendly_http_error(status: int | None, detail: str = "") -> str:
    if status is None:
        head = "网络连接失败，请检查网络或 Base URL。"
    elif status == 400:
        head = "请求被拒绝（参数或模型可能不受支持）。"
    elif status == 401:
        head = "认证失败：API Key 无效或已过期。"
    elif status == 403:
        head = "没有权限访问该模型或接口。"
    elif status == 404:
        head = "接口或模型不存在，请检查 Base URL 与模型名。"
    elif status == 413:
        head = "请求内容过长。"
    elif status == 429:
        head = "请求过于频繁或额度已用尽，请稍后重试。"
    elif status is not None and status >= 500:
        head = "服务端错误，请稍后重试。"
    else:
        head = f"API 返回错误（HTTP {status}）。"
    detail = detail.strip()
    if detail:
        return f"{head}\n{detail}"
    return head


def normalize_messages(messages: Sequence[dict[str, Any]]) -> list[dict[str, str]]:
    """Validate history and merge consecutive same-role turns.

    The Anthropic API accepts consecutive turns, but some compatible gateways
    do not; merging keeps us portable.
    """
    normalized: list[dict[str, str]] = []
    for message in messages:
        role = message.get("role")
        content = message.get("content")
        if role not in ("user", "assistant") or not isinstance(content, str):
            continue
        content = content.strip()
        if not content:
            continue
        if normalized and normalized[-1]["role"] == role:
            normalized[-1]["content"] += "\n\n" + content
        else:
            normalized.append({"role": role, "content": content})
    while normalized and normalized[0]["role"] != "user":
        normalized.pop(0)
    return normalized


def openai_endpoint(base_url: str) -> str:
    url = base_url.strip().rstrip("/")
    if not url:
        raise APIError(None, "Base URL 不能为空。")
    if url.endswith("/chat/completions"):
        return url
    return url + "/chat/completions"


def anthropic_base_url(base_url: str) -> str:
    url = base_url.strip().rstrip("/")
    if not url:
        raise APIError(None, "Base URL 不能为空。")
    for suffix in ("/v1/messages", "/messages"):
        if url.endswith(suffix):
            url = url[: -len(suffix)].rstrip("/")
            break
    if url.endswith("/v1"):
        url = url[:-3].rstrip("/")
    return url or "https://api.anthropic.com"


def _text_from(value: Any) -> str:
    """Extract text from the many shapes gateways use for content parts."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                part = item.get("text") or item.get("content")
                if isinstance(part, str):
                    parts.append(part)
        return "".join(parts)
    if isinstance(value, dict):
        for key in ("content", "text", "thinking", "reasoning"):
            part = value.get(key)
            if isinstance(part, str):
                return part
    return ""


def extract_openai_delta(payload: dict[str, Any]) -> tuple[str, str]:
    """Return ``(text, reasoning)`` from one OpenAI streaming chunk."""
    text_parts: list[str] = []
    reasoning_parts: list[str] = []
    choices = payload.get("choices")
    if not isinstance(choices, list):
        return "", ""
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            delta = choice.get("message")
        if not isinstance(delta, dict):
            continue
        text = _text_from(delta.get("content"))
        if text:
            text_parts.append(text)
        reasoning = _text_from(
            delta.get("reasoning_content")
            or delta.get("reasoning")
            or delta.get("thinking")
        )
        if reasoning:
            reasoning_parts.append(reasoning)
    return "".join(text_parts), "".join(reasoning_parts)


def openai_error_detail(payload: dict[str, Any]) -> str | None:
    error = payload.get("error")
    if not error:
        return None
    if isinstance(error, str):
        return error
    if isinstance(error, dict):
        message = error.get("message") or error.get("detail") or error.get("type")
        if isinstance(message, str):
            return message
    return "接口返回了未知错误。"


def _decode_error_body(body: bytes, api_key: str) -> str:
    text = body.decode("utf-8", errors="replace")
    try:
        payload = json.loads(text)
    except ValueError:
        return _scrub(text, api_key)
    if isinstance(payload, dict):
        detail = openai_error_detail(payload)
        if detail:
            return _scrub(detail, api_key)
        for key in ("message", "detail"):
            value = payload.get(key)
            if isinstance(value, str):
                return _scrub(value, api_key)
    return _scrub(text, api_key)


async def stream_chat(
    *,
    provider: str,
    base_url: str,
    model: str,
    api_key: str,
    messages: Sequence[dict[str, Any]],
    system_prompt: str = "",
    max_tokens: int = 8192,
    temperature: float | None = 0.7,
    request_thinking: bool = True,
    on_text: TextCallback,
    on_thinking: TextCallback,
    on_notice: NoticeCallback | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> None:
    """Stream one assistant reply, invoking callbacks as chunks arrive."""
    normalized = normalize_messages(messages)
    if not normalized:
        raise APIError(None, "没有可发送的消息。")
    if provider == "anthropic":
        await _stream_anthropic(
            base_url=base_url,
            model=model,
            api_key=api_key,
            messages=normalized,
            system_prompt=system_prompt,
            max_tokens=max_tokens,
            request_thinking=request_thinking,
            on_text=on_text,
            on_thinking=on_thinking,
            on_notice=on_notice,
        )
    elif provider == "openai":
        await _stream_openai(
            base_url=base_url,
            model=model,
            api_key=api_key,
            messages=normalized,
            system_prompt=system_prompt,
            max_tokens=max_tokens,
            temperature=temperature,
            on_text=on_text,
            on_thinking=on_thinking,
            transport=transport,
        )
    else:
        raise APIError(None, f"不支持的接口格式：{provider}")


async def _stream_anthropic(
    *,
    base_url: str,
    model: str,
    api_key: str,
    messages: list[dict[str, str]],
    system_prompt: str,
    max_tokens: int,
    request_thinking: bool,
    on_text: TextCallback,
    on_thinking: TextCallback,
    on_notice: NoticeCallback | None,
) -> None:
    url = anthropic_base_url(base_url)
    try:
        async with anthropic.AsyncAnthropic(
            api_key=api_key,
            base_url=url,
            timeout=600.0,
            max_retries=0,
        ) as client:
            use_thinking = request_thinking
            while True:
                produced = False

                async def wrapped_text(chunk: str) -> None:
                    nonlocal produced
                    produced = True
                    await _emit(on_text, chunk)

                async def wrapped_thinking(chunk: str) -> None:
                    nonlocal produced
                    produced = True
                    await _emit(on_thinking, chunk)

                kwargs: dict[str, Any] = {
                    "model": model,
                    "max_tokens": max_tokens,
                    "messages": messages,
                }
                if system_prompt.strip():
                    kwargs["system"] = system_prompt
                if use_thinking:
                    # Adaptive thinking + summarized display is how current
                    # Claude models expose readable reasoning while streaming.
                    kwargs["thinking"] = {
                        "type": "adaptive",
                        "display": "summarized",
                    }
                try:
                    async with client.messages.stream(**kwargs) as stream:
                        async for event in stream:
                            if event.type != "content_block_delta":
                                continue
                            delta = event.delta
                            if delta.type == "text_delta":
                                await wrapped_text(delta.text)
                            elif delta.type == "thinking_delta":
                                await wrapped_thinking(delta.thinking)
                    if not produced:
                        raise APIError(None, "接口返回了空响应。")
                    return
                except anthropic.BadRequestError as exc:
                    detail = _scrub(str(exc), api_key)
                    if (
                        use_thinking
                        and not produced
                        and "thinking" in detail.lower()
                    ):
                        use_thinking = False
                        await _emit(
                            on_notice,
                            "当前模型不支持 adaptive thinking，"
                            "已自动关闭思维链参数并重试。",
                        )
                        continue
                    raise APIError(
                        getattr(exc, "status_code", 400),
                        friendly_http_error(
                            getattr(exc, "status_code", 400), detail
                        ),
                    ) from None
                except anthropic.AuthenticationError as exc:
                    raise APIError(
                        401,
                        friendly_http_error(401, _scrub(str(exc), api_key)),
                    ) from None
                except anthropic.APIStatusError as exc:
                    status = getattr(exc, "status_code", None)
                    raise APIError(
                        status,
                        friendly_http_error(status, _scrub(str(exc), api_key)),
                    ) from None
                except anthropic.APIConnectionError as exc:
                    raise APIError(
                        None,
                        friendly_http_error(None, _scrub(str(exc), api_key)),
                    ) from None
    except APIError:
        raise
    except asyncio.CancelledError:
        raise
    except anthropic.AnthropicError as exc:
        raise APIError(None, _scrub(str(exc), api_key)) from None


async def _consume_openai_sse(
    lines: AsyncIterator[str],
    *,
    api_key: str,
    on_text: TextCallback,
    on_thinking: TextCallback,
) -> bool:
    """Consume OpenAI SSE lines. Returns True if any content was emitted."""
    produced = False
    async for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith(":"):
            continue
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        error = openai_error_detail(event)
        if error:
            raise APIError(None, _scrub(error, api_key))
        text, reasoning = extract_openai_delta(event)
        if reasoning:
            produced = True
            await _emit(on_thinking, reasoning)
        if text:
            produced = True
            await _emit(on_text, text)
    return produced


async def _stream_openai(
    *,
    base_url: str,
    model: str,
    api_key: str,
    messages: list[dict[str, str]],
    system_prompt: str,
    max_tokens: int,
    temperature: float | None,
    on_text: TextCallback,
    on_thinking: TextCallback,
    transport: httpx.AsyncBaseTransport | None,
) -> None:
    url = openai_endpoint(base_url)
    payload_messages: list[dict[str, str]] = []
    if system_prompt.strip():
        payload_messages.append({"role": "system", "content": system_prompt})
    payload_messages.extend(messages)
    payload: dict[str, Any] = {
        "model": model,
        "messages": payload_messages,
        "stream": True,
    }
    if max_tokens:
        payload["max_tokens"] = max_tokens
    if temperature is not None:
        payload["temperature"] = temperature
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    timeout = httpx.Timeout(connect=15.0, read=600.0, write=60.0, pool=15.0)

    try:
        async with httpx.AsyncClient(
            timeout=timeout,
            transport=transport,
            follow_redirects=False,
        ) as client, client.stream(
            "POST", url, headers=headers, json=payload
        ) as response:
            if response.status_code >= 400:
                body = await response.aread()
                detail = _decode_error_body(body, api_key)
                raise APIError(
                    response.status_code,
                    friendly_http_error(response.status_code, detail),
                )

            content_type = response.headers.get("content-type", "")
            if "text/event-stream" not in content_type.lower():
                # Some gateways ignore stream=true and return JSON — or return
                # SSE bodies without the expected content-type.
                body = await response.aread()
                decoded = body.decode("utf-8", errors="replace")
                first_line = next(
                    (line.strip() for line in decoded.splitlines() if line.strip()),
                    "",
                )
                if first_line.startswith(("data:", "event:", ":")):

                    async def body_lines() -> AsyncIterator[str]:
                        for line in decoded.splitlines():
                            yield line

                    produced = await _consume_openai_sse(
                        body_lines(),
                        api_key=api_key,
                        on_text=on_text,
                        on_thinking=on_thinking,
                    )
                    if not produced:
                        raise APIError(None, "接口返回了空响应。")
                    return

                text, reasoning = _parse_openai_completion(body, api_key)
                if reasoning:
                    await _emit(on_thinking, reasoning)
                if text:
                    await _emit(on_text, text)
                if not text and not reasoning:
                    raise APIError(None, "接口返回了空响应。")
                return

            produced = await _consume_openai_sse(
                response.aiter_lines(),
                api_key=api_key,
                on_text=on_text,
                on_thinking=on_thinking,
            )
        if not produced:
            raise APIError(None, "接口返回了空响应。")
    except APIError:
        raise
    except asyncio.CancelledError:
        raise
    except httpx.TimeoutException:
        raise APIError(None, "请求超时。") from None
    except httpx.RequestError as exc:
        raise APIError(None, friendly_http_error(None, str(exc))) from None


def _parse_openai_completion(body: bytes, api_key: str) -> tuple[str, str]:
    try:
        payload = json.loads(body.decode("utf-8", errors="replace"))
    except ValueError:
        raise APIError(None, "接口返回了无法解析的响应。") from None
    if not isinstance(payload, dict):
        raise APIError(None, "接口返回了无法解析的响应。")
    error = openai_error_detail(payload)
    if error:
        raise APIError(None, _scrub(error, api_key))
    text_parts: list[str] = []
    reasoning_parts: list[str] = []
    choices = payload.get("choices")
    if isinstance(choices, list):
        for choice in choices:
            if not isinstance(choice, dict):
                continue
            message = choice.get("message")
            if not isinstance(message, dict):
                continue
            text_parts.append(_text_from(message.get("content")))
            reasoning_parts.append(
                _text_from(
                    message.get("reasoning_content")
                    or message.get("reasoning")
                    or message.get("thinking")
                )
            )
    return "".join(text_parts), "".join(reasoning_parts)
