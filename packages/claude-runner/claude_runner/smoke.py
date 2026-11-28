"""Opt-in Messages API smoke for one synthetic translation and review."""

import argparse
import json
from contextlib import closing
from os import getenv

from .budget import ROLES, Usage
from .client import ApiError, Client, FatalApiError
from .transport_anthropic import AnthropicTransport


MODEL = "claude-sonnet-5-5"
OFFICIAL_BASE_URL = "https://api.anthropic.com"
UNIT_ID = "synthetic-1"
SOURCE = "Amber kite"
TRANSLATION = "琥珀色風箏"
TRANSLATOR_SYSTEM = (
    "Translate the single synthetic unit to Traditional Chinese for Taiwan. "
    "For this fixture, use the exact glossary entry Amber kite = 琥珀色風箏. "
    "Return one item with the same unitId and its translation."
)
REVIEWER_SYSTEM = (
    "Review the single synthetic unit independently. The expected translation of Amber kite "
    "is exactly 琥珀色風箏. Return one item with the same unitId and verdict pass "
    "if the source and translation match that pair, otherwise return verdict reject."
)


def output_schema(field, definition):
    return {
        "type": "object",
        "properties": {
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {"unitId": {"type": "string"}, field: definition},
                    "required": ["unitId", field],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["items"],
        "additionalProperties": False,
    }


def check(client, role, system, unit, field, definition):
    result = client.call(role, system, {"units": [unit]}, output_schema(field, definition), [UNIT_ID])
    if result.model != MODEL:
        raise FatalApiError("model_mismatch")
    return result.items[UNIT_ID][field]


def _unsafe_environment_code():
    if getenv("ANTHROPIC_BASE_URL") not in (None, OFFICIAL_BASE_URL, f"{OFFICIAL_BASE_URL}/"):
        return "unsafe_api_base_url"
    if getenv("ANTHROPIC_LOG") in ("debug", "info"):
        return "sdk_logging_enabled"
    if getenv("ANTHROPIC_CUSTOM_HEADERS"):
        return "sdk_custom_headers_configured"
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--live", action="store_true", required=True, help="Call Anthropic for the fixed case")
    parser.parse_args(argv)
    if code := _unsafe_environment_code():
        print(json.dumps({"status": "failed", "code": code}))
        return 1

    api_key = getenv("ANTHROPIC_API_KEY")
    if not api_key:
        print(json.dumps({"status": "failed", "code": "missing_api_key"}))
        return 1

    usage = Usage()
    fixture = {"unitId": UNIT_ID, "source": SOURCE}
    stage = "setup"
    try:
        with closing(AnthropicTransport(api_key, timeout=30)) as transport:
            client = Client(transport, MODEL, dict.fromkeys(ROLES, "medium"), 512, (), usage)
            stage = "translator"
            translation = check(client, stage, TRANSLATOR_SYSTEM, fixture, "translation", {"type": "string"})
            if translation != TRANSLATION:
                raise FatalApiError("translation_mismatch")

            stage = "reviewer"
            verdict = check(client, stage, REVIEWER_SYSTEM, {**fixture, "translation": translation},
                            "verdict", {"type": "string", "enum": ["pass", "reject"]})
            if verdict != "pass":
                raise FatalApiError("review_rejected")
            stage = "cleanup"
    except ApiError as error:
        print(json.dumps({"status": "failed", "stage": stage, "code": error.code}))
        return 1
    except Exception:
        print(json.dumps({"status": "failed", "stage": stage, "code": "unexpected_failure"}))
        return 1

    print(json.dumps({
        "status": "passed",
        "model": MODEL,
        "requests": sum(counters["requests"] for counters in usage.data.values()),
        "inputTokens": sum(counters["input_tokens"] for counters in usage.data.values()),
        "outputTokens": sum(counters["output_tokens"] for counters in usage.data.values()),
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
