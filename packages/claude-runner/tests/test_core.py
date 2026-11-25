import json
from types import SimpleNamespace

import pytest

from claude_runner.budget import Usage
from claude_runner.cache import Cache, cache_key
from claude_runner.client import Client, FakeTransport, FatalApiError, Response, RetryableApiError
from claude_runner.transport_anthropic import classify_error, request_arguments, retry_after


def response(items, **kwargs):
    return Response(text=json.dumps({"items": items}), **kwargs)


def request(client, ids=("a",)):
    return client.call("translator", "system", {"units": []},
                       {"type": "object", "required": ["items"]}, ids)


@pytest.mark.parametrize("bad", [
    response([], stop_reason="max_tokens"), response([], stop_reason="refusal"),
    Response(text=None), response([]), response([{"unitId": "a"}, {"unitId": "a"}]),
    response([{"unitId": "b"}]), response([{"unitId": "a"}, {"unitId": "b"}]),
    Response(text="malformed"), Response(text="{}"),
])
def test_4_2_and_4_8_retry_whole_response(bad):
    transport = FakeTransport([bad, response([{"unitId": "a"}])])
    sleeps = []
    usage = Usage()
    assert request(Client(transport, "model", {"translator": "medium"}, 100, [5, 20, 60],
                          usage, sleeps.append)).items["a"]["unitId"] == "a"
    assert sleeps == [5]
    assert transport.requests[0] == transport.requests[1]
    assert usage.data["translator"]["retries"] == 1


def test_4_8_retry_after_and_limit():
    transport = FakeTransport([RetryableApiError("rate_limited", 12)] +
                              [RetryableApiError("overloaded")] * 3)
    sleeps = []
    with pytest.raises(RetryableApiError, match="overloaded"):
        request(Client(transport, "model", {"translator": "medium"}, 100, [5, 20, 60],
                       Usage(), sleeps.append))
    assert sleeps == [12, 20, 60]
    assert len(transport.requests) == 4


def test_4_8_fatal_does_not_retry():
    transport = FakeTransport([FatalApiError("authentication")])
    with pytest.raises(FatalApiError):
        request(Client(transport, "model", {"translator": "medium"}, 100, [5], Usage(),
                       lambda _: pytest.fail("fatal retry")))
    assert len(transport.requests) == 1


@pytest.mark.parametrize("index", range(6))
def test_ac6_every_cache_component_must_match(tmp_path, index):
    cache = Cache(tmp_path)
    identity = ["source", None, "rules", "glossary", "update", "model"]
    result = {"segments": {"s1": "譯文"}, "expression": '"譯文"', "review": {"verdict": "pass"}}
    cache.put(identity, result)
    assert cache.get(identity) == result
    assert (tmp_path / cache_key(identity)[:2] / (cache_key(identity) + ".json")).is_file()
    other = identity.copy()
    other[index] = "changed"
    assert cache.get(other) is None


@pytest.mark.parametrize(("name", "status", "kind", "code"), [
    ("RateLimitError", 429, RetryableApiError, "rate_limit"),
    ("OverloadedError", 529, RetryableApiError, "overloaded"),
    ("InternalServerError", 500, RetryableApiError, "server_error"),
    ("ServiceUnavailableError", 503, RetryableApiError, "server_error"),
    ("GatewayTimeoutError", 504, RetryableApiError, "server_error"),
    ("APITimeoutError", None, RetryableApiError, "timeout"),
    ("APIConnectionError", None, RetryableApiError, "connection"),
    ("APIStatusError", 599, RetryableApiError, "server_error"),
    ("APIStatusError", 422, FatalApiError, "api_request_failed"),
    ("AuthenticationError", 401, FatalApiError, "authentication"),
    ("PermissionDeniedError", 403, FatalApiError, "authentication"),
    ("BadRequestError", 400, FatalApiError, "api_request_failed"),
    ("NotFoundError", 404, FatalApiError, "api_request_failed"),
    ("RequestTooLargeError", 413, FatalApiError, "api_request_failed"),
    ("PaymentRequiredError", 402, FatalApiError, "spend_limit"),
    ("EnforcedSpendLimitReachedError", 429, FatalApiError, "spend_limit"),
])
def test_4_8_sdk_error_classification_without_transport(name, status, kind, code):
    import anthropic

    sdk_type = getattr(anthropic, name)
    error = sdk_type.__new__(sdk_type)
    error.status_code = status
    error.response = SimpleNamespace(headers={"retry-after": "8.5"})
    translated = classify_error(anthropic, error)
    assert type(translated) is kind
    assert translated.code == code
    if kind is RetryableApiError:
        assert translated.retry_after == 8.5


@pytest.mark.parametrize("bad_header", [None, "later", "NaN", "-3", "inf"])
def test_4_8_retry_after_ignores_invalid_values(bad_header):
    import anthropic

    error = anthropic.RateLimitError.__new__(anthropic.RateLimitError)
    error.status_code = 429
    error.response = SimpleNamespace(headers={"retry-after": bad_header})
    assert classify_error(anthropic, error).retry_after == 0


def test_4_15_sdk_request_argument_shape():
    transport = FakeTransport([response([{"unitId": "a"}])])
    request(Client(transport, "model", {"translator": "medium"}, 100, [], Usage()))
    args = request_arguments(transport.requests[0])
    assert set(args) == {"model", "max_tokens", "system", "messages", "output_config"}
    assert args["system"] == [{"type": "text", "text": "system", "cache_control": {"type": "ephemeral"}}]
    assert args["messages"][0]["role"] == "user"
    assert json.loads(args["messages"][0]["content"]) == {"units": []}
    assert args["output_config"] == {
        "effort": "medium",
        "format": {"type": "json_schema", "schema": transport.requests[0].schema},
    }


def test_4_8_retry_after_http_date_uses_injected_clock():
    error = SimpleNamespace(
        response=SimpleNamespace(headers={"retry-after": "Thu, 01 Jan 1970 00:01:00 GMT"}))
    assert retry_after(error, clock=lambda: 45) == 15
    assert retry_after(error, clock=lambda: 75) == 0
