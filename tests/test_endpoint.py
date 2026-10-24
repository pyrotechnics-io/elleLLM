"""Exercise the OpenAI-compatible endpoint with the official OpenAI SDK."""

import requests

from conftest import API_KEY

MESSAGES = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Say hello in one short sentence."},
]


def test_list_models(client):
    ids = [m.id for m in client.models.list().data]
    assert "phi-4-mini" in ids


def test_chat_completion(client):
    resp = client.chat.completions.create(
        model="phi-4-mini",
        messages=MESSAGES,
        max_tokens=16,
        temperature=0.2,
    )
    assert resp.object == "chat.completion"
    assert len(resp.choices) == 1
    choice = resp.choices[0]
    assert choice.message.role == "assistant"
    assert isinstance(choice.message.content, str)
    assert choice.finish_reason in ("stop", "length")
    assert 0 < resp.usage.completion_tokens <= 16
    assert resp.usage.total_tokens == resp.usage.prompt_tokens + resp.usage.completion_tokens


def test_chat_completion_stream(client):
    stream = client.chat.completions.create(
        model="phi-4-mini",
        messages=MESSAGES,
        max_tokens=16,
        stream=True,
    )
    chunks = list(stream)
    assert chunks, "expected at least one streamed chunk"
    assert all(c.object == "chat.completion.chunk" for c in chunks)
    assert chunks[-1].choices[0].finish_reason in ("stop", "length")
    text = "".join(c.choices[0].delta.content or "" for c in chunks)
    assert isinstance(text, str)


def test_rejects_missing_api_key(base_url):
    r = requests.post(
        f"{base_url}/chat/completions",
        json={"model": "phi-4-mini", "messages": MESSAGES, "max_tokens": 4},
        timeout=60,
    )
    assert r.status_code == 401


def test_raw_http_shape(base_url):
    r = requests.post(
        f"{base_url}/chat/completions",
        headers={"Authorization": f"Bearer {API_KEY}"},
        json={"model": "phi-4-mini", "messages": MESSAGES, "max_tokens": 8},
        timeout=120,
    )
    r.raise_for_status()
    body = r.json()
    assert body["choices"][0]["message"]["role"] == "assistant"
    assert "content" in body["choices"][0]["message"]
