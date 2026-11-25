"""官方 SDK 的同步 transport。直到建構 transport 時才載入 SDK。"""

import json
import math
import time
from email.utils import parsedate_to_datetime

from .client import FatalApiError, Response, RetryableApiError


def retry_after(error, clock=time.time):
    headers = getattr(getattr(error, "response", None), "headers", None) or {}
    value = headers.get("retry-after")
    if value is None:
        return 0
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        try:
            timestamp = parsedate_to_datetime(value)
            if timestamp.tzinfo is None:
                return 0
            seconds = timestamp.timestamp() - clock()
        except (TypeError, ValueError, OverflowError, OSError):
            return 0
    return seconds if math.isfinite(seconds) and seconds >= 0 else 0


def classify_error(sdk, error):
    if isinstance(error, (sdk.EnforcedSpendLimitReachedError, sdk.PaymentRequiredError)):
        return FatalApiError("spend_limit")
    if isinstance(error, (sdk.AuthenticationError, sdk.PermissionDeniedError)):
        return FatalApiError("authentication")
    if isinstance(error, sdk.APITimeoutError):
        return RetryableApiError("timeout", retry_after(error))
    if isinstance(error, sdk.APIConnectionError):
        return RetryableApiError("connection", retry_after(error))
    if isinstance(error, sdk.APIStatusError):
        status = error.status_code
        if isinstance(error, sdk.OverloadedError) or status == 529:
            return RetryableApiError("overloaded", retry_after(error))
        if isinstance(error, sdk.RateLimitError) or status == 429:
            return RetryableApiError("rate_limit", retry_after(error))
        if isinstance(error, sdk.InternalServerError) or status >= 500:
            return RetryableApiError("server_error", retry_after(error))
    return FatalApiError("api_request_failed")


def request_arguments(request):
    return {
        "model": request.model,
        "max_tokens": request.max_tokens,
        "system": [{"type": "text", "text": request.system,
                    "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": json.dumps(request.user, ensure_ascii=False)}],
        "output_config": {"effort": request.effort,
                          "format": {"type": "json_schema", "schema": request.schema}},
    }


class AnthropicTransport:
    def __init__(self, api_key, timeout):
        import anthropic

        self.sdk = anthropic
        try:
            self.client = anthropic.Anthropic(api_key=api_key, max_retries=0, timeout=timeout)
        except (anthropic.AnthropicError, ValueError):
            raise FatalApiError("api_request_failed") from None

    def send(self, request):
        try:
            message = self.client.messages.create(**request_arguments(request))
        except self.sdk.AnthropicError as error:
            raise classify_error(self.sdk, error) from None
        text = next((block.text for block in message.content if block.type == "text"), None)
        return Response(text=text, model=message.model, stop_reason=message.stop_reason,
                        usage=message.usage.model_dump())

    def close(self):
        self.client.close()
