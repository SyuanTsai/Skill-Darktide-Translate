"""Schema 15 工作集的 Claude 翻譯轉接器。"""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import sys
import time

# 原始碼工作樹可直接執行。獨立 Skill 安裝則使用環境中的套件。
source_package = Path(__file__).resolve().parent.parent / "claude-runner"
if (source_package / "claude_runner/__init__.py").is_file():
    sys.path.insert(0, str(source_package))

from claude_runner.batch import BatchCallbacks, Progress, batches, process_batch
from claude_runner.budget import Usage, estimated_cost, exceeds_budget
from claude_runner.cache import Cache
from claude_runner.client import Client, FatalApiError
from claude_runner.state import State, StateMismatch

from checks import FORMAT, MARKUP, Luac, strip_unexpected_outer_quotes, validate
from gameplay_context import INSUFFICIENT, fingerprint, load_context
from glossary import Glossary
from lua_template import ComplexExpression, Expression, Template, decode_string, token_shape, tokenize
from rules import ASSETS_RELATIVE, MODES, load_config, load_rules
from summary import api_message, write_summary
from workset import Workset, WorksetError, expression


API_KEY_VARIABLE = "ANTHROPIC_API_KEY"
LOOKUP = "needs_lookup_definition"
COMPLEX = "complex_expression"
CONTEXT_BLOCK = object()


def positive_int(text):
    number = int(text)
    if number <= 0:
        raise argparse.ArgumentTypeError("需為正整數")
    return number


def parser():
    commands = argparse.ArgumentParser(description="Darktide 臺灣繁中翻譯工作集")
    sub = commands.add_subparsers(dest="command", required=True)
    for name in ("run", "binding"):
        command = sub.add_parser(name)
        command.add_argument("--mods-root", type=Path, required=True)
        command.add_argument("--mode", default="update", choices=MODES)
    binding = sub.choices["binding"]
    binding.add_argument("--mod-relative-path", required=True)
    binding.add_argument("--base-oid")
    run = sub.choices["run"]
    for name in ("workset", "state", "cache-dir", "summary-out"):
        run.add_argument(f"--{name}", type=Path, required=True)
    run.add_argument("--max-items", type=positive_int)
    run.add_argument("--gameplay-context", type=Path)
    run.add_argument("--dry-run", action="store_true")
    return commands


def cache_identity(unit, binding):
    return [
        expression(unit, "new", "sourceExpression"),
        expression(unit, "old", "zhTwExpression"),
        binding["rulesSha256"], binding["glossarySha256"], binding["mode"], binding["modelId"],
    ]


class Requests:
    def __init__(self, rules, workset, templates, glossary, contexts):
        self.rules = rules
        self.units = workset.pending
        self.templates = templates
        self.glossary = glossary
        self.contexts = contexts
        self.mode = rules.binding["mode"]
        self.system = {role: rules.system(role) for role in ("translator", "reviewer")}
        self.schemas = {
            role: json.loads(rules.files["skill", f"{ASSETS_RELATIVE}/api-{role}-output.schema.json"])
            for role in self.system
        }

    def user(self, unit_ids, units):
        glossary = self.glossary.slice(
            " ".join(self.templates[unit_id].segments.values()) for unit_id in unit_ids
        )
        return {"mode": self.mode, "glossarySha256": self.rules.binding["glossarySha256"],
                "glossary": glossary, "units": units}

    def translator_payload(self, unit_ids, progress):
        units = []
        for unit_id in unit_ids:
            unit = self.units[unit_id]
            units.append({
                "unitId": unit_id, "key": unit.get("key"), "containerPath": unit.get("containerPath"),
                "source": self.templates[unit_id].segments,
                "previousEnglish": expression(unit, "old", "sourceExpression"),
                "previousZhTw": expression(unit, "old", "zhTwExpression"),
                "candidateZhTw": expression(unit, "new", "zhTwExpression"),
                "feedback": progress[unit_id].feedback,
            })
        return self.user(unit_ids, units)

    def translator_schema(self, unit_ids):
        schema = copy.deepcopy(self.schemas["translator"])
        segment_schema = schema["properties"]["items"]["items"]["properties"]
        text_schema = segment_schema["segments"]["additionalProperties"]
        shapes = sorted({len(self.templates[unit_id].segments) for unit_id in unit_ids})
        options = []
        for count in shapes:
            names = [f"s{number}" for number in range(1, count + 1)]
            options.append({"type": "object", "properties": dict.fromkeys(names, text_schema),
                            "required": names, "additionalProperties": False})
        segment_schema["segments"] = options[0] if len(options) == 1 else {"anyOf": options}
        return schema

    def translate(self, client, unit_ids, progress):
        return client.call("translator", self.system["translator"],
                           self.translator_payload(unit_ids, progress),
                           self.translator_schema(unit_ids), unit_ids)

    def reviewer_payload(self, values):
        units = []
        for unit_id, value in values.items():
            unit = {"unitId": unit_id, "source": self.templates[unit_id].segments,
                    "translation": value["segments"]}
            if unit_id in self.contexts:
                context = self.contexts[unit_id]
                unit["key"] = context["key"]
                unit["gameplayContext"] = {name: data for name, data in context.items() if name != "key"}
            units.append(unit)
        return self.user(values, units)

    def review(self, client, values):
        return client.call("reviewer", self.system["reviewer"],
                           self.reviewer_payload(values), self.schemas["reviewer"], values)

    def estimate(self, queue, batch_size, progress, prices):
        totals = {"input_tokens": 0, "output_tokens": 0}
        for unit_ids in batches(queue, batch_size):
            reviewed = {unit_id: {"segments": self.templates[unit_id].segments} for unit_id in unit_ids}
            for role, payload in (("translator", self.translator_payload(unit_ids, progress)),
                                  ("reviewer", self.reviewer_payload(reviewed))):
                # 以 UTF-8 位元組近似輸入 token，輸出採逐項固定估值。
                size = len((self.system[role] + json.dumps(payload, ensure_ascii=False)).encode("utf-8"))
                totals["input_tokens"] += (size + 3) // 4
                totals["output_tokens"] += len(unit_ids) * (150 if role == "translator" else 60)
        return {**totals, "estimatedUsd": estimated_cost(totals, prices)}


def inspect_translation(template, item, glossary, luac):
    segments, warnings = strip_unexpected_outer_quotes(template, item["segments"])
    lookup = item["needsLookupDefinition"]
    value = {"segments": segments, "unknownTerms": item["unknownTerms"], "warnings": warnings}
    if lookup:
        value["termReview"] = {"reason": LOOKUP, "adoption": "translation",
                               "terms": item["unknownTerms"] or text_fragments(template.segments.values())}
        if (isinstance(segments, dict) and segments.keys() == template.segments.keys()
                and all(isinstance(text, str) for text in segments.values())
                and (segments == template.segments or not any(text.strip() for text in segments.values()))):
            return None, ["lookup_text_missing"], value
    rendered, issues = validate(template, segments, glossary, luac)
    return None, issues, {**value, "expression": rendered}


def text_fragments(texts):
    return list(dict.fromkeys(text.strip() for text in texts
                              if not re.fullmatch(r"loc_[A-Za-z0-9_]+", text)
                              and re.search(r"[^\W\d_]", FORMAT.sub("", MARKUP.sub("", text)))))


def lookup_adoption(unit, template, glossary, luac):
    for side in ("new", "old"):
        raw = expression(unit, side, "zhTwExpression")
        if not raw:
            continue
        try:
            existing = Template.parse(raw)
        except ComplexExpression:
            continue
        if (token_shape(existing.tokens) == token_shape(template.tokens)
                and any(text.strip() for text in existing.segments.values())
                and not validate(template, existing.segments, glossary, luac, check_terms=False)[1]
                and luac.accepts(raw)):
            return raw, "existing_zh_tw"
    if luac.accepts(template.raw):
        return template.raw, "english_fallback"
    return None, None


def preserve_expression(unit, raw, luac):
    try:
        tokens = tokenize(raw)
        existing = expression(unit, "new", "zhTwExpression")
        for value in (raw, existing):
            if value is None:
                continue
            if not luac.accepts(value):
                return None
            if not luac.available:
                Expression(tokenize(value), allow_opaque_strings=True).parse()
                for token in tokenize(value):
                    if token.kind == "string":
                        decode_string(token.text)
    except (ValueError, OverflowError, RecursionError):
        return None
    texts = []
    for token in tokens:
        if token.kind == "string":
            try:
                texts.append(decode_string(token.text))
            except (ValueError, OverflowError):
                texts.append(token.text)
    return {"segments": None, "expression": existing or raw, "unknownTerms": [], "warnings": [],
            "termReview": {"reason": COMPLEX, "adoption": "preserved_expression", "terms": text_fragments(texts)}}


def valid_approval(record, template, glossary, luac):
    if not isinstance(record, dict) or not isinstance(record.get("review"), dict):
        return False
    if record["review"].get("verdict") != "pass" or needs_gameplay_context(record["review"].get("issues")):
        return False
    rendered, issues = validate(template, record.get("segments"), glossary, luac)
    return not issues and rendered == record.get("expression")


def needs_gameplay_context(issues):
    return isinstance(issues, list) and any(
        isinstance(issue, dict) and issue.get("category") == "gameplay_context" for issue in issues)


def prepare(workset, state, cache, binding, glossary, luac, contexts, context_blockers):
    templates, identities, progress = {}, {}, {}
    ready, queue = {}, []
    for unit_id, unit in workset.pending.items():
        record = state.units.get(unit_id, {})
        step = Progress(record.get("attempts", 0), record.get("corrections", 0),
                        record.get("feedback", []), record.get("cacheable", True))
        progress[unit_id] = step
        if record.get("status") == "blocked" and record.get("blockedReason") not in ("api_failed", LOOKUP, COMPLEX):
            continue
        if unit_id in context_blockers:
            ready[unit_id] = (context_blockers[unit_id], None)
            continue
        identity = cache_identity(unit, binding)
        if unit_id in contexts:
            identity.append(fingerprint([unit_id, contexts[unit_id]]))
        try:
            template = Template.parse(identity[0] or "")
        except ComplexExpression:
            if unit_id in contexts:
                ready[unit_id] = (INSUFFICIENT, None)
                continue
            preserved = preserve_expression(unit, identity[0] or "", luac)
            ready[unit_id] = ("preserved", preserved) if preserved else ("invalid_lua_expression", None)
            continue
        templates[unit_id], identities[unit_id] = template, identity
        if record.get("status") == "approved":
            adoption = (record.get("termReview") or {}).get("adoption")
            if adoption in ("english_fallback", "existing_zh_tw"):
                valid = lookup_adoption(unit, template, glossary, luac) == (record["expression"], adoption)
            else:
                valid = valid_approval(record, template, glossary, luac)
            if not valid:
                raise StateMismatch("狀態檔中的已核准結果無法重新驗證，請移除舊狀態檔或改用新的 --state 路徑。")
            ready[unit_id] = ("resume", record)
            continue
        cached = cache.get(identity)
        if valid_approval(cached, template, glossary, luac):
            ready[unit_id] = ("cache", {
                "segments": cached["segments"], "expression": cached["expression"],
                "review": {**cached["review"], "unitId": unit_id},
                "unknownTerms": cached.get("unknownTerms", []), "warnings": cached.get("warnings", []),
                "termReview": cached.get("termReview"),
            })
        else:
            queue.append(unit_id)
    return templates, identities, progress, ready, queue


def distinct_paths(args):
    paths = [path.resolve() for path in
             (args.workset, args.state, args.summary_out, args.summary_out.with_suffix(".md"))]
    if len(set(paths)) != len(paths):
        raise WorksetError("工作集、狀態檔與兩種摘要必須使用不同路徑。")
    if args.gameplay_context is not None and args.gameplay_context.resolve() in paths:
        raise WorksetError("遊戲脈絡檔必須使用獨立路徑。")
    return paths


def run(args, config, transport, sleeper, luac):
    distinct_paths(args)
    workset = Workset(args.workset)
    base_oid = (workset.document["baseOid"] or "") if workset.document.get("generatorVersion") == 2 else None
    rules = load_rules(args.mods_root, args.mode, workset.document["modRelativePath"], config, base_oid=base_oid)
    binding = workset.bind(rules.binding)
    contexts, context_blockers = load_context(args.gameplay_context, args.mods_root, workset)
    identity = {"worksetSha256": workset.document["immutableContractSha256"],
                "rulesSha": binding["rulesSha256"], "glossarySha": binding["glossarySha256"],
                "mode": binding["mode"], "model": binding["modelId"],
                "gameplayContextSha256": fingerprint([contexts, context_blockers])
                if contexts or context_blockers else None}
    state = State(args.state, identity)
    usage = Usage(state.data["usage"])
    state.data["usage"] = usage.data
    cache = Cache(args.cache_dir)
    glossary = Glossary.parse(rules.glossary.decode("utf-8-sig"))
    templates, identities, progress, ready, queue = prepare(
        workset, state, cache, binding, glossary, luac, contexts, context_blockers)
    requests = Requests(rules, workset, templates, glossary, contexts)
    limit = args.max_items if args.max_items is not None else config["maxItemsPerRun"]
    prices = config["pricingUsdPerMTok"]
    batch_size = config["batchSize"]
    report = {
        "status": "completed", "mode": binding["mode"], "model": binding["modelId"],
        "rulesSha256": binding["rulesSha256"], "rulesManifest": binding["rulesManifest"],
        "glossarySha256": binding["glossarySha256"],
        "nonAiCount": sum(unit["action"] != "AI_REQUIRED" for unit in workset.units),
        "pendingCount": len(workset.pending), "apiItemCount": len(queue),
        "batchCount": (len(queue) + batch_size - 1) // batch_size, "batchSize": batch_size,
        "maxItems": limit, "maxItemsOverride": args.max_items, "dryRun": args.dry_run,
        "luacAvailable": luac.available, "pricingSource": config["pricingSource"],
        "estimate": requests.estimate(queue, batch_size, progress, prices),
    }
    approvals = {}
    preview = {}

    def finish(unit_id, step, reason, *, value=None, review=None, details=None, origin="api"):
        if value is CONTEXT_BLOCK or (review and needs_gameplay_context(review.get("issues"))):
            reason, value, review = INSUFFICIENT, None, None
            step.feedback = []
        status = "blocked" if reason else "preserved" if origin == "preserved" else "approved"
        record = {
            "status": status,
            "attempts": step.attempts, "corrections": step.corrections,
            "segments": value["segments"] if value else None,
            "expression": value["expression"] if value else None,
            "unknownTerms": value["unknownTerms"] if value else [],
            "warnings": value["warnings"] if value else [],
            "review": review, "blockedReason": reason,
            "feedback": step.feedback, "cacheable": step.cacheable, "origin": origin,
        }
        unit = workset.pending[unit_id]
        if value and value.get("termReview"):
            record["termReview"] = value["termReview"]
        if record["unknownTerms"] or record.get("termReview"):
            record["key"] = unit.get("key", unit_id)
            record["source"] = expression(unit, "new", "sourceExpression")
        if details:
            record["details"] = details
        if reason is None:
            approvals[unit_id] = (status, None if status == "preserved" else record["expression"])
        if args.dry_run:
            preview[unit_id] = record
            return
        state.set_unit(unit_id, record)
        if review is not None and origin == "api" and step.cacheable:
            cache.put(identities[unit_id], {**value, "review": review})

    def fallback(unit_id, value, issues, exhausted):
        if needs_gameplay_context(issues):
            # A context gap needs new evidence. Route it to finish without another translation attempt.
            return CONTEXT_BLOCK
        if unit_id in contexts:
            return None
        if not value or not value.get("termReview"):
            return None
        term_only = issues == ["glossary_term_missing"] or (
            issues and all(isinstance(issue, dict) and issue.get("category") == "term" for issue in issues))
        if issues != ["lookup_text_missing"] and not (exhausted and term_only):
            return None
        unit, template = workset.pending[unit_id], templates[unit_id]
        raw, adoption = lookup_adoption(unit, template, glossary, luac)
        if raw is None:
            return None
        return {**value, "segments": None, "expression": raw, "warnings": [],
                "termReview": {**value["termReview"], "adoption": adoption}}

    def summarize(status, message=None):
        report["status"] = status
        if message:
            report["message"] = message
        write_summary(args.summary_out, report, {**state.units, **preview}, usage, prices)

    if exceeds_budget(len(queue), limit):
        for unit_id, (origin, value) in ready.items():
            if origin != "resume":
                preview[unit_id] = {"origin": origin, "blockedReason": origin if value is None else None}
        summarize("needs-confirmation", "待送項目超過單次上限。")
        return 2

    real_transport = None
    if queue and not args.dry_run and transport is None:
        try:
            api_key = os.environ[API_KEY_VARIABLE]
        except KeyError:
            api_key = ""
        if not api_key.strip():
            message = "缺少 ANTHROPIC_API_KEY 環境變數。"
            summarize("missing-key", message)
            print(message, file=sys.stderr)
            return 5
        from claude_runner.transport_anthropic import AnthropicTransport
        try:
            real_transport = transport = AnthropicTransport(api_key, config["requestTimeoutSeconds"])
        except FatalApiError as error:
            summarize("api-failed", api_message(error.code))
            return 3

    try:
        for unit_id, (origin, value) in ready.items():
            if value is None:
                finish(unit_id, progress[unit_id], origin)
            elif origin == "resume":
                approvals[unit_id] = ("approved", value["expression"])
            else:
                finish(unit_id, progress[unit_id], None, value=value, review=value.get("review"), origin=origin)
        if args.dry_run:
            summarize("dry-run")
            return 0

        client = Client(transport, binding["modelId"], config["effort"], config["maxOutputTokens"],
                        config["retryBackoffSeconds"], usage, sleeper, state.save)
        callbacks = BatchCallbacks(
            translate=lambda ids, steps: requests.translate(client, ids, steps),
            inspect=lambda unit_id, item: inspect_translation(templates[unit_id], item, glossary, luac),
            review=lambda values: requests.review(client, values),
            finish=finish,
            fallback=fallback,
        )
        error = None
        for unit_ids in batches(queue, batch_size):
            error = process_batch(unit_ids, progress, binding["modelId"],
                                  config["maxCorrectionsPerItem"], callbacks)
            if error:
                break

        workset.fill(approvals)
        if not args.state.exists():
            state.save()
        if error:
            message = api_message(error.code)
            summarize("api-failed", message)
            print(message, file=sys.stderr)
            return 3
        summarize("completed")
        return 0
    finally:
        if real_transport is not None:
            real_transport.close()


def main(argv=None, *, transport=None, sleeper=time.sleep, luac=None):
    try:
        args = parser().parse_args(argv)
    except SystemExit as error:
        return 4 if error.code else 0

    try:
        config = load_config()
        if args.command == "binding":
            rules = load_rules(args.mods_root, args.mode, args.mod_relative_path, config, base_oid=args.base_oid)
            print(json.dumps(rules.binding, ensure_ascii=True, indent=2))
            return 0
        return run(args, config, transport, sleeper, Luac.discover() if luac is None else luac)
    except (StateMismatch, WorksetError) as error:
        print(error, file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, OverflowError):
        print("輸入、設定或輸出路徑無效，請核對工作集、規則、狀態及寫入權限。", file=sys.stderr)
    return 4


if __name__ == "__main__":
    raise SystemExit(main())
