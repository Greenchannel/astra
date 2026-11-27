from __future__ import annotations

import json

import httpx
import pytest

from astra.client import (
    APIError,
    anthropic_base_url,
    extract_openai_delta,
    normalize_messages,
    openai_endpoint,
    stream_chat,
)


def test_normalize_messages_merges_and_filters() -> None:
    messages = [
        {"role": "assistant", "content": "ignore me"},
        {"role": "user", "content": " hello "},
        {"role": "user", "content": "world"},
        {"role": "assistant", "content": "hi"},
        {"role": "tool", "content": "nope"},
        {"role": "user", "content": "   "},
    ]
    assert normalize_messages(messages) == [
        {"role": "user", "content": "hello\n\nworld"},
        {"role": "assistant", "content": "hi"},
    ]


def test_endpoint_normalization() -> None:
    assert openai_endpoint("https://api.openai.com/v1/") == (
        "https://api.openai.com/v1/chat/completions"
    )
    assert openai_endpoint("https://proxy.test/chat/completions") == (
        "https://proxy.test/chat/completions"
    )
    assert anthropic_base_url("https://api.anthropic.com") == (
        "https://api.anthropic.com"
    )
    assert anthropic_base_url("https://proxy.test/v1/messages/") == (
        "https://proxy.test"
    )
    assert anthropic_base_url("https://proxy.test/v1") == "https://proxy.test"


def test_extract_openai_delta_shapes() -> None:
    assert extract_openai_delta(
        {"choices": [{"delta": {"content": "Hello ", "reasoning_content": "hmm"}}]}
    ) == ("Hello ", "hmm")
    assert extract_openai_delta(
        {
            "choices": [
                {
                    "delta": {
                        "content": [{"type": "text", "text": "A"}, {"text": "B"}],
                        "reasoning": {"content": "why"},
                    }
                }
            ]
        }
    ) == ("AB", "why")
    assert extract_openai_delta({"choices": [{"delta": {}}]}) == ("", "")
    assert extract_openai_delta({"choices": []}) == ("", "")


async def test_openai_streaming_request_and_callbacks() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["headers"] = dict(request.headers)
        captured["payload"] = json.loads(request.content)
        chunks = [
            {"choices": [{"delta": {"reasoning_content": "想一想"}}]},
            {"choices": [{"delta": {"content": "你"}}]},
            {"choices": [{"delta": {"content": "好"}}]},
            {"choices": [{"delta": {}, "finish_reason": "stop"}]},
        ]
        body = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks)
        body += "data: [DONE]\n\n"
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content=body.encode(),
        )

    text: list[str] = []
    thinking: list[str] = []
    await stream_chat(
        provider="openai",
        base_url="https://example.test/v1",
        model="test-model",
        api_key="sk-secret",
        messages=[{"role": "user", "content": "你好"}],
        system_prompt="",
        max_tokens=128,
        temperature=0.3,
        request_thinking=True,
        on_text=text.append,
        on_thinking=thinking.append,
        transport=httpx.MockTransport(handler),
    )

    assert "".join(text) == "你好"
    assert "".join(thinking) == "想一想"
    assert captured["url"] == "https://example.test/v1/chat/completions"
    assert captured["headers"]["authorization"] == "Bearer sk-secret"
    payload = captured["payload"]
    assert payload["model"] == "test-model"
    assert payload["stream"] is True
    assert payload["max_tokens"] == 128
    assert payload["temperature"] == 0.3
    assert payload["messages"] == [{"role": "user", "content": "你好"}]


async def test_openai_sse_without_event_stream_content_type() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        body = (
            'data: {"choices":[{"delta":{"content":"仍然流式"}}]}\n\n'
            "data: [DONE]\n\n"
        )
        return httpx.Response(
            200,
            headers={"content-type": "text/plain"},
            content=body.encode(),
        )

    text: list[str] = []
    await stream_chat(
        provider="openai",
        base_url="https://example.test/v1",
        model="m",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
        temperature=None,
        on_text=text.append,
        on_thinking=lambda _: None,
        transport=httpx.MockTransport(handler),
    )
    assert "".join(text) == "仍然流式"


async def test_openai_omits_null_temperature() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["payload"] = json.loads(request.content)
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content=b'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n',
        )

    await stream_chat(
        provider="openai",
        base_url="https://example.test/v1",
        model="m",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
        system_prompt="You are helpful.",
        temperature=None,
        on_text=lambda _: None,
        on_thinking=lambda _: None,
        transport=httpx.MockTransport(handler),
    )
    assert "temperature" not in captured["payload"]
    assert captured["payload"]["messages"][0] == {
        "role": "system",
        "content": "You are helpful.",
    }


async def test_openai_error_scrubs_api_key() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401,
            json={"error": {"message": "invalid key sk-super-secret"}},
        )

    with pytest.raises(APIError) as excinfo:
        await stream_chat(
            provider="openai",
            base_url="https://example.test/v1",
            model="test-model",
            api_key="sk-super-secret",
            messages=[{"role": "user", "content": "hi"}],
            on_text=lambda _: None,
            on_thinking=lambda _: None,
            transport=httpx.MockTransport(handler),
        )

    assert excinfo.value.status == 401
    assert "sk-super-secret" not in excinfo.value.message
    assert "REDACTED" in excinfo.value.message


async def test_anthropic_streaming_request(monkeypatch) -> None:
    import httpx2
    from anthropic import AsyncAnthropic

    import astra.client as client_module

    captured: dict = {}
    events = [
        {
            "type": "message_start",
            "message": {
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "model": "claude-opus-5",
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 5, "output_tokens": 1},
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": "", "signature": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "先想"},
        },
        {"type": "content_block_stop", "index": 0},
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "text", "text": ""},
        },
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "text_delta", "text": "你好"},
        },
        {"type": "content_block_stop", "index": 1},
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 8},
        },
        {"type": "message_stop"},
    ]
    body = "".join(
        f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events
    )

    def handler(request: httpx2.Request) -> httpx2.Response:
        captured["url"] = str(request.url)
        captured["headers"] = dict(request.headers)
        captured["payload"] = json.loads(request.content)
        return httpx2.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content=body.encode(),
        )

    transport = httpx2.MockTransport(handler)
    real_client = AsyncAnthropic

    def factory(**kwargs):
        captured["client_kwargs"] = kwargs
        return real_client(
            api_key=kwargs["api_key"],
            base_url=kwargs["base_url"],
            http_client=httpx2.AsyncClient(transport=transport),
            max_retries=0,
        )

    monkeypatch.setattr(client_module.anthropic, "AsyncAnthropic", factory)
    text: list[str] = []
    thinking: list[str] = []
    await stream_chat(
        provider="anthropic",
        base_url="https://api.anthropic.com/v1",
        model="claude-opus-5",
        api_key="sk-ant-test",
        messages=[{"role": "user", "content": "你好"}],
        system_prompt="",
        max_tokens=512,
        request_thinking=True,
        on_text=text.append,
        on_thinking=thinking.append,
    )

    assert "".join(text) == "你好"
    assert "".join(thinking) == "先想"
    assert captured["url"] == "https://api.anthropic.com/v1/messages"
    payload = captured["payload"]
    assert payload["model"] == "claude-opus-5"
    assert payload["max_tokens"] == 512
    assert payload["thinking"] == {"type": "adaptive", "display": "summarized"}
    assert "system" not in payload
    assert "temperature" not in payload
    assert captured["client_kwargs"]["base_url"] == "https://api.anthropic.com"


async def test_openai_non_sse_json_fallback() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"content-type": "application/json"},
            json={
                "choices": [
                    {
                        "message": {
                            "content": "完整回复",
                            "reasoning_content": "完整思考",
                        }
                    }
                ]
            },
        )

    text: list[str] = []
    thinking: list[str] = []
    await stream_chat(
        provider="openai",
        base_url="https://example.test/v1",
        model="m",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
        on_text=text.append,
        on_thinking=thinking.append,
        transport=httpx.MockTransport(handler),
    )
    assert text == ["完整回复"]
    assert thinking == ["完整思考"]
