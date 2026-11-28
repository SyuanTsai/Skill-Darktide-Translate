import json

import anthropic
import httpx2
import pytest

from claude_runner import smoke


@pytest.fixture
def mock_messages(monkeypatch):
    original_client = anthropic.Anthropic
    requests = []
    clients = []

    def install(responses, *, base_url=None):
        responses = iter(responses)

        def handle(request):
            requests.append(request)
            status, body = next(responses)
            return httpx2.Response(status, json=body)

        def make_client(**kwargs):
            assert kwargs == {"api_key": "synthetic-test-key", "timeout": 30, "max_retries": 0}
            http_client = httpx2.Client(transport=httpx2.MockTransport(handle))
            clients.append(http_client)
            return original_client(http_client=http_client, **kwargs)

        monkeypatch.setenv("ANTHROPIC_API_KEY", "synthetic-test-key")
        if base_url is None:
            monkeypatch.delenv("ANTHROPIC_BASE_URL", raising=False)
        else:
            monkeypatch.setenv("ANTHROPIC_BASE_URL", base_url)
        monkeypatch.delenv("ANTHROPIC_LOG", raising=False)
        monkeypatch.delenv("ANTHROPIC_CUSTOM_HEADERS", raising=False)
        monkeypatch.setattr(anthropic, "Anthropic", make_client)
        return requests, clients

    return install


def response(item, *, model="claude-sonnet-5-5"):
    return {
        "id": "msg_synthetic",
        "type": "message",
        "role": "assistant",
        "model": model,
        "stop_reason": "end_turn",
        "content": [{"type": "text", "text": json.dumps({"items": [item]})}],
        "usage": {"input_tokens": 12, "output_tokens": 8},
    }


# Scenario: The command runs without the live flag.
# Purpose: Require explicit opt-in before reading credentials or constructing the SDK.
def test_UnitT10_requires_live_opt_in_before_accessing_credentials(monkeypatch, capsys):
    def unexpected(*args, **kwargs):
        pytest.fail("Live smoke accessed a credential or constructed its transport")

    monkeypatch.setattr(smoke, "getenv", unexpected)
    monkeypatch.setattr(smoke, "AnthropicTransport", unexpected)

    with pytest.raises(SystemExit) as error:
        smoke.main([])

    assert error.value.code == 2
    assert "--live" in capsys.readouterr().err


# Scenario: The live flag is present but the API credential is absent.
# Purpose: Fail with a fixed diagnostic before creating a transport.
def test_UnitT20_reports_missing_credential_without_constructing_transport(monkeypatch, capsys):
    def unexpected(*args, **kwargs):
        pytest.fail("Live smoke constructed its transport without credentials")

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_BASE_URL", raising=False)
    monkeypatch.delenv("ANTHROPIC_LOG", raising=False)
    monkeypatch.delenv("ANTHROPIC_CUSTOM_HEADERS", raising=False)
    monkeypatch.setattr(smoke, "AnthropicTransport", unexpected)

    assert smoke.main(["--live"]) == 1
    assert json.loads(capsys.readouterr().out) == {"status": "failed", "code": "missing_api_key"}


# Scenario: Live smoke inherits an alternate endpoint, SDK logging, or custom headers.
# Purpose: Reject unsafe settings before credential access and omit their values from diagnostics.
@pytest.mark.parametrize(("name", "value", "code"), [
    ("ANTHROPIC_BASE_URL", "", "unsafe_api_base_url"),
    ("ANTHROPIC_BASE_URL", "http://api.anthropic.com", "unsafe_api_base_url"),
    ("ANTHROPIC_BASE_URL", "https://api.anthropic.com.example.invalid", "unsafe_api_base_url"),
    ("ANTHROPIC_BASE_URL", "https://api.anthropic.com@alternate.example.invalid", "unsafe_api_base_url"),
    ("ANTHROPIC_BASE_URL", "https://api.anthropic.com/path", "unsafe_api_base_url"),
    ("ANTHROPIC_LOG", "debug", "sdk_logging_enabled"),
    ("ANTHROPIC_LOG", "info", "sdk_logging_enabled"),
    ("ANTHROPIC_CUSTOM_HEADERS", "Authorization: raw-ambient-value", "sdk_custom_headers_configured"),
])
def test_UnitT25_rejects_unsafe_sdk_environment_before_credential_access(name, value, code, monkeypatch, capsys):
    def get_setting(key):
        assert key != "ANTHROPIC_API_KEY", "Live smoke read its credential before environment validation"
        return value if key == name else None

    def unexpected(*args, **kwargs):
        pytest.fail("Live smoke constructed its transport with unsafe SDK settings")

    monkeypatch.setattr(smoke, "getenv", get_setting)
    monkeypatch.setattr(smoke, "AnthropicTransport", unexpected)

    assert smoke.main(["--live"]) == 1

    captured = capsys.readouterr()
    assert captured.err == ""
    assert json.loads(captured.out) == {"status": "failed", "code": code}


# Scenario: The mocked SDK endpoint returns a valid translation and review.
# Purpose: Pin the synthetic data, structured requests, output limit, and sanitized evidence.
@pytest.mark.parametrize("base_url", [None, "https://api.anthropic.com", "https://api.anthropic.com/"])
def test_InterT30_sends_two_structured_requests_and_reports_usage(base_url, mock_messages, capsys):
    requests, clients = mock_messages([
        (200, response({"unitId": "synthetic-1", "translation": "琥珀色風箏"})),
        (200, response({"unitId": "synthetic-1", "verdict": "pass"})),
    ], base_url=base_url)

    assert smoke.main(["--live"]) == 0

    assert len(requests) == 2
    assert clients[0].is_closed
    assert all(str(request.url) == "https://api.anthropic.com/v1/messages" for request in requests)
    assert all(request.headers["authorization"] == "Bearer synthetic-test-key" for request in requests)
    translation, review = [json.loads(request.content) for request in requests]
    fixture = {"unitId": "synthetic-1", "source": "Amber kite"}
    for body, result_field in [(translation, "translation"), (review, "verdict")]:
        assert body["model"] == "claude-sonnet-5-5"
        assert body["max_tokens"] == 512
        assert body["system"][0]["cache_control"] == {"type": "ephemeral"}
        assert body["output_config"]["effort"] == "medium"
        output_format = body["output_config"]["format"]
        assert output_format["type"] == "json_schema"
        item_schema = output_format["schema"]["properties"]["items"]["items"]
        assert item_schema["required"] == ["unitId", result_field]
    assert json.loads(translation["messages"][0]["content"]) == {"units": [fixture]}
    assert json.loads(review["messages"][0]["content"]) == {
        "units": [{**fixture, "translation": "琥珀色風箏"}],
    }
    assert json.loads(capsys.readouterr().out) == {
        "status": "passed",
        "model": "claude-sonnet-5-5",
        "requests": 2,
        "inputTokens": 24,
        "outputTokens": 16,
    }


# Scenario: The first provider reply is retryable, invalid, or from a different model.
# Purpose: Terminate after one call and discard provider text and response model.
@pytest.mark.parametrize(("status", "body", "code"), [
    (429, {"type": "error", "error": {"type": "rate_limit_error", "message": "raw-provider-value"}},
     "rate_limit"),
    (200, response({"unitId": "invalid", "translation": "raw-provider-value"}), "unit_id_mismatch"),
    (200, response({"unitId": "synthetic-1", "translation": "琥珀色風箏"}, model="raw-provider-value"),
     "model_mismatch"),
    (200, response({"unitId": "synthetic-1", "translation": "raw-provider-value"}),
     "translation_mismatch"),
])
def test_InterT40_stops_on_failed_translation_with_sanitized_summary(
    status, body, code, mock_messages, capsys,
):
    requests, clients = mock_messages([(status, body)])

    assert smoke.main(["--live"]) == 1

    assert len(requests) == 1
    assert clients[0].is_closed
    assert json.loads(capsys.readouterr().out) == {
        "status": "failed", "stage": "translator", "code": code,
    }


# Scenario: A valid translation receives a schema-valid review rejection.
# Purpose: Require a passing review before reporting a successful live smoke.
def test_InterT50_fails_when_the_reviewer_rejects_the_translation(mock_messages, capsys):
    requests, clients = mock_messages([
        (200, response({"unitId": "synthetic-1", "translation": "琥珀色風箏"})),
        (200, response({"unitId": "synthetic-1", "verdict": "reject"})),
    ])

    assert smoke.main(["--live"]) == 1

    assert len(requests) == 2
    assert clients[0].is_closed
    assert json.loads(capsys.readouterr().out) == {
        "status": "failed", "stage": "reviewer", "code": "review_rejected",
    }
