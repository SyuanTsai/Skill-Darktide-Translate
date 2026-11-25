"""結構化輸出、請求對應與唯一一層 API 重試。"""

import json
import math
import time
from dataclasses import dataclass, field
from typing import Protocol

from jsonschema import Draft202012Validator, ValidationError


class ApiError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class RetryableApiError(ApiError):
    def __init__(self, code, retry_after=0):
        super().__init__(code)
        self.retry_after = retry_after


class FatalApiError(ApiError):
    pass


@dataclass(frozen=True)
class Request:
    role: str
    model: str
    effort: str
    max_tokens: int
    system: str
    user: dict
    schema: dict


@dataclass(frozen=True)
class Response:
    text: str | None
    model: str | None = None
    stop_reason: str | None = None
    usage: dict = field(default_factory=dict)


class Transport(Protocol):
    def send(self, request: Request) -> Response: ...


class FakeTransport:
    """應答可為 Response、核心例外，或接受本次 Request 的函式。"""

    def __init__(self, responses):
        self.responses = iter(responses)
        self.requests = []

    def send(self, request):
        self.requests.append(request)
        try:
            answer = next(self.responses)
        except StopIteration:
            raise AssertionError("FakeTransport 收到未預期的請求") from None
        if isinstance(answer, Exception):
            raise answer
        return answer(request) if callable(answer) else answer


@dataclass(frozen=True)
class Result:
    items: dict
    model: str | None


def _decode(response, validator, expected):
    if response.stop_reason in ("max_tokens", "refusal"):
        raise RetryableApiError(response.stop_reason)
    if not response.text or not response.text.strip():
        raise RetryableApiError("empty_response")
    try:
        document = json.loads(response.text)
        validator.validate(document)
        items = document["items"]
        paired = {item["unitId"]: item for item in items}
        if len(items) != len(paired) or paired.keys() != expected:
            raise RetryableApiError("unit_id_mismatch")
    except (ValueError, ValidationError, KeyError, TypeError):
        raise RetryableApiError("invalid_output") from None
    return Result(paired, response.model)


class Client:
    def __init__(self, transport: Transport, model, effort, max_tokens, backoff, usage,
                 sleeper=time.sleep, save_usage=lambda: None):
        self.transport = transport
        self.model = model
        self.effort = effort
        self.max_tokens = max_tokens
        self.backoff = tuple(backoff)
        self.usage = usage
        self.sleeper = sleeper
        self.save_usage = save_usage

    def call(self, role, system, user, schema, unit_ids):
        request = Request(role, self.model, self.effort[role], self.max_tokens, system, user, schema)
        validator = Draft202012Validator(schema)
        expected = set(unit_ids)
        for attempt in range(len(self.backoff) + 1):
            response = None
            try:
                response = self.transport.send(request)
                return _decode(response, validator, expected)
            except RetryableApiError as error:
                if attempt == len(self.backoff):
                    raise
                delay = error.retry_after
                delay = delay if isinstance(delay, (int, float)) and math.isfinite(delay) else 0
                delay = max(self.backoff[attempt], delay)
            finally:
                self.usage.record(role, retry=attempt > 0, tokens=response.usage if response else None)
                self.save_usage()
            self.sleeper(delay)
