import copy
import hashlib
import json
from pathlib import Path
import subprocess

import pytest

from claude_runner.client import FakeTransport, FatalApiError, Response, RetryableApiError
from checks import Luac
from darktide_translate import main
from rules import SKILL_ROOT, load_rules

FIXTURES = Path(__file__).parent / "fixtures"
WORDS = "sk-ant-TEST-DO-NOT-LOG-0000"
MODEL = "claude-sonnet-5-5"


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


class Run:
    def __init__(self, path):
        self.path = path
        self.workset = path / "localization-workset.json"
        self.state = path / "api-state.json"
        self.summary = path / "api-summary.json"
        self.cache = path / "cache"
        self.mods = path / "mods-root"
        self.doc = read(FIXTURES / "workset.json")
        self.base = copy.deepcopy(self.doc["units"][0])
        for spec in read(SKILL_ROOT / "assets/api-rules-manifest.json")["files"]:
            if spec["repo"] == "mods":
                target = self.mods / spec["path"]
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"Sample rules\r\n")
        glossary = self.mods / "Referneces/Translation.md"
        glossary.parent.mkdir()
        glossary.write_bytes((FIXTURES / "terms.md").read_bytes())
        self.doc["translationBinding"] = load_rules(self.mods, "update", "mods/TestMod").binding

    def add(self, index, english):
        unit = copy.deepcopy(self.base)
        for item in (unit, unit["old"], unit["new"]):
            item["unitId"] += str(index)
            item["key"] += str(index)
        unit["new"]["sourceExpression"]["raw"] = english
        self.doc["units"].append(unit)

    def save(self):
        self.workset.write_text(json.dumps(self.doc, ensure_ascii=False, indent=2), encoding="utf-8")

    def run(self, transport, *flags, luac=None):
        argv = ["run", "--workset", str(self.workset), "--state", str(self.state),
                "--summary-out", str(self.summary), "--cache-dir", str(self.cache),
                "--mods-root", str(self.mods), *flags]
        return main(argv, transport=transport, sleeper=lambda _: None, luac=luac or Luac(None))


@pytest.fixture
def job(tmp_path):
    return Run(tmp_path)


def scripted(translation="增加15%", *, model=MODEL, issues=(), unknown=(), lookup=False):
    def respond(request):
        units = request.user["units"]
        if request.role == "translator":
            items = [{"unitId": unit["unitId"], "segments": {"s1": translation},
                      "unknownTerms": list(unknown), "needsLookupDefinition": lookup}
                     for unit in units]
        else:
            items = [{"unitId": unit["unitId"], "verdict": "fail" if issues else "pass",
                      "issues": list(issues)} for unit in units]
        return Response(json.dumps({"items": items}), model=model, usage={
            "input_tokens": 40, "output_tokens": 20,
            "cache_creation_input_tokens": 50, "cache_read_input_tokens": 100})
    return respond


@pytest.mark.parametrize("action", ["RESTORE_OLD_ZH_TW", "NONE"])
def test_ac1_keep_unchanged_unit(job, action):
    unit = job.doc["units"][0]
    unit["new"]["sourceExpression"] = unit["old"]["sourceExpression"]
    unit.update(action=action, reviewStatus="not-required")
    job.save()
    previous = job.workset.read_bytes()
    transport = FakeTransport([])
    assert job.run(transport) == 0
    assert job.workset.read_bytes() == previous
    assert not transport.requests
    assert read(job.summary)["nonAiCount"] == 1


def test_ac1_preserves_other_unit_bytes_with_bom_and_crlf(job):
    job.add(2, '"Gain 15%"')
    job.doc["units"][1].update(action="RESTORE_OLD_ZH_TW", reviewStatus="not-required")
    previous = json.dumps(job.doc, ensure_ascii=True, indent=4).replace("\n", "\r\n").encode("utf-8-sig")
    job.workset.write_bytes(previous)
    assert job.run(FakeTransport([scripted(), scripted()])) == 0
    assert job.workset.read_bytes() == previous.replace(
        b'"reviewStatus": "pending",\r\n            "suggestedZhTwExpression": null',
        '"reviewStatus": "approved",\r\n            "suggestedZhTwExpression": "\\"增加15%\\""'.encode("utf-8"),
        1,
    )


def test_ac2_and_4_3_structure_then_semantic_correction(job):
    job.save()
    transport = FakeTransport([
        scripted("增加10%"), scripted(),
        scripted(issues=[{"category": "negation", "detail": "應保留否定"}]),
        scripted(), scripted(),
    ])
    assert job.run(transport) == 0
    requests = transport.requests
    assert [r.role for r in requests] == ["translator", "translator", "reviewer", "translator", "reviewer"]
    assert "number_mismatch" in str(requests[1].user["units"][0]["feedback"])
    assert "negation" in str(requests[3].user["units"][0]["feedback"])
    assert set(requests[2].user["units"][0]) == {"unitId", "source", "translation"}
    original = copy.deepcopy(job.doc)
    original["units"][0].update(reviewStatus="approved", suggestedZhTwExpression='"增加15%"')
    rewritten = read(job.workset)
    assert rewritten == original and list(rewritten) == list(original)
    record = next(iter(read(job.state)["units"].values()))
    assert record["corrections"] == 2
    assert record["attempts"] == 3


def test_ac3_and_4_2_batches_and_term_slices(job):
    job.doc["units"].clear()
    for index in range(120):
        job.add(index, '"Finesse"')
    job.save()
    transport = FakeTransport([scripted("靈巧")] * 6)
    assert job.run(transport) == 0
    translators = transport.requests[::2]
    assert [len(r.user["units"]) for r in translators] == [50, 50, 20]
    assert [u["unitId"] for r in translators for u in r.user["units"]] == [
        u["unitId"] for u in job.doc["units"]]
    assert translators[0].user["glossary"] == translators[1].user["glossary"] == translators[2].user["glossary"]
    assert "範圍：" in str(translators[0].user["glossary"])
    assert "Flamer" not in str(translators[0].user["glossary"])
    assert len({r.system for r in translators}) == 1


@pytest.mark.parametrize("field,value", [("status", "blocked"), ("schemaVersion", 2),
                                         ("workflowSchemaVersion", 14)])
def test_4_2_cannot_read_wrong_workset(job, field, value):
    job.doc[field] = value
    job.save()
    assert job.run(FakeTransport([])) == 4


@pytest.mark.parametrize("key", ["mode", "modelId", "rulesSha256", "glossarySha256", "rulesManifest", None])
def test_4_11_binding_required_and_matches(job, key):
    if key is None:
        del job.doc["translationBinding"]
    else:
        job.doc["translationBinding"][key] = "wrong"
    job.save()
    assert job.run(FakeTransport([])) == 4


def test_v2_run_uses_base_blobs_when_checkout_bytes_differ(job, capsys):
    def git(*args):
        return subprocess.run(["git", "-C", str(job.mods), *args], check=True,
                              capture_output=True).stdout.decode("ascii").strip()

    git("init", "--quiet")
    git("-c", "core.autocrlf=false", "add", "--", ".")
    job.doc["baseOid"] = git("write-tree")
    job.doc["generatorVersion"] = 2
    glossary = job.mods / "Referneces/Translation.md"
    glossary.write_bytes(b"Different checkout bytes\r\n")
    job.save()

    assert job.run(FakeTransport([]), "--dry-run") == 0
    capsys.readouterr()
    assert main(["binding", "--mods-root", str(job.mods), "--mod-relative-path", "mods/TestMod",
                 "--base-oid", job.doc["baseOid"]]) == 0
    assert json.loads(capsys.readouterr().out) == job.doc["translationBinding"]


def test_4_11_manifest_digest_and_ed_filter(job, capsys):
    for mode, path in [("update", "mods/TestMod"), ("improve", "mods/Enhanced_descriptions")]:
        assert main(["binding", "--mode", mode, "--mod-relative-path", path,
                     "--mods-root", str(job.mods)]) == 0
        binding = json.loads(capsys.readouterr().out)
        rows = binding["rulesManifest"]
        assert rows == sorted(rows, key=lambda row: (row["repo"], row["path"]))
        data = "".join(f"{r['repo']}\t{r['path']}\t{r['sha256']}\n" for r in rows).encode()
        assert hashlib.sha256(data).hexdigest() == binding["rulesSha256"]
        assert hashlib.sha256((job.mods / "Referneces/Translation.md").read_bytes()).hexdigest() == binding["glossarySha256"]
        paths = str(rows)
        assert ("enhanced_descriptions" in paths) == (mode == "improve")
        assert ("zh-tw_initial_translation_rules.md" in paths) == (mode == "update")
        assert ("zh-tw_revision_rules.md" in paths) == (mode == "improve")


def test_ac5_and_4_9_partial_progress_and_resume(job):
    job.add(2, '"Next 20%"')
    job.save()

    def translate_both(request):
        return Response(json.dumps({"items": [
            {"unitId": unit["unitId"], "segments": {"s1": text}, "unknownTerms": [],
             "needsLookupDefinition": False}
            for unit, text in zip(request.user["units"], ["增加15%", "下一項10%"])
        ]}), model=MODEL)

    transport = FakeTransport([translate_both, scripted(), *[RetryableApiError("overloaded")] * 4])
    assert job.run(transport) == 3
    first, second = read(job.workset)["units"]
    assert first["reviewStatus"] == "approved"
    assert second["reviewStatus"] == "pending" and second["suggestedZhTwExpression"] is None
    assert read(job.summary)["blocked"][0]["reason"] == "api_failed"
    assert read(job.state)["units"][first["unitId"]]["status"] == "approved"
    resumed = FakeTransport([scripted("下一項20%"), scripted()])
    assert job.run(resumed) == 0
    assert all(r.user["units"][0]["unitId"] == second["unitId"] for r in resumed.requests)
    assert all(u["reviewStatus"] == "approved" for u in read(job.workset)["units"])


def test_ac5_reviewer_failure_stops_prompt_and_can_resume(job):
    job.save()
    transport = FakeTransport([scripted(), FatalApiError("spend_limit")])
    assert job.run(transport) == 3
    assert read(job.summary)["message"] == "帳戶花費上限已到"
    assert "帳戶花費上限已到" in job.summary.with_suffix(".md").read_text(encoding="utf-8")
    assert len(transport.requests) == 2
    assert read(job.workset)["units"][0]["reviewStatus"] == "pending"
    assert not list(job.cache.rglob("*.json"))
    assert job.run(FakeTransport([scripted(), scripted()])) == 0


@pytest.mark.parametrize("key", ["worksetSha256", "rulesSha", "glossarySha", "mode", "model"])
def test_4_9_resume_rejects_different_identity(job, key):
    job.save()
    assert job.run(FakeTransport([scripted(), scripted()])) == 0
    state = read(job.state)
    state[key] = "wrong"
    job.state.write_text(json.dumps(state), encoding="utf-8")
    assert job.run(FakeTransport([])) == 4


@pytest.mark.parametrize("model", [MODEL, "other-model"])
def test_ac6_and_4_10_zero_api_cache_hit_and_model_guard(job, model):
    job.save()
    assert job.run(FakeTransport([scripted(model=model), scripted()])) == 0
    job.state.unlink()
    job.save()
    transport = FakeTransport([] if model == MODEL else [scripted(), scripted()])
    assert job.run(transport) == 0
    assert len(transport.requests) == (0 if model == MODEL else 2)
    assert read(job.summary)["cacheHitCount"] == (1 if model == MODEL else 0)


@pytest.mark.parametrize(("reason", "replies"), [
    ("needs_lookup_definition", [scripted(lookup=True)]),
    ("unknown_term", [scripted(unknown=["unrecognized"])]),
    ("max_corrections_reached", [scripted("增加10%")] * 3),
    ("complex_expression", []),
])
def test_4_7_blocked_remains_pending(job, reason, replies):
    if reason == "complex_expression":
        job.doc["units"][0]["new"]["sourceExpression"]["raw"] = 'Localize("key")'
    job.save()
    assert job.run(FakeTransport(replies)) == 0
    assert read(job.summary)["blocked"][0]["reason"] == reason
    assert read(job.workset)["units"][0]["reviewStatus"] == "pending"
    assert list(job.cache.rglob("*.json")) == []


@pytest.mark.parametrize("dry", [True, False])
def test_4_12_budget_and_explicit_override(job, dry):
    for index in range(500):
        job.add(index, '"Gain 15%"')
    job.save()
    flags = ["--dry-run"] if dry else []
    assert job.run(FakeTransport([]), *flags) == 2
    summary = read(job.summary)
    assert summary["status"] == "needs-confirmation"
    assert summary["apiItemCount"] == 501 and summary["estimate"]["estimatedUsd"] > 0
    assert job.run(FakeTransport([scripted()] * 22), "--max-items", "800", *flags) == 0
    assert read(job.summary)["maxItemsOverride"] == 800
    assert ("上限經人工覆寫為 800" in job.summary.with_suffix(".md").read_text(encoding="utf-8"))


def test_4_13_usage_and_4_15_request_shape(job):
    job.save()
    transport = FakeTransport([scripted(), scripted()])
    assert job.run(transport) == 0
    for request in transport.requests:
        assert request.model == MODEL and request.effort == "medium"
        assert request.max_tokens == 32000
        assert "Sample rules" in request.system
        assert request.schema["properties"]["items"]["type"] == "array"
    summary = read(job.summary)
    for role in ("translator", "reviewer"):
        assert summary["usage"][role]["cache_creation_input_tokens"] == 50
        assert summary["usage"][role]["requests"] == 1
    assert summary["estimatedUsageUsd"] == pytest.approx(0.00083)
    assert str(job.path) not in job.summary.with_suffix(".md").read_text(encoding="utf-8")
    assert summary["luacAvailable"] is False


def test_4_14_fake_key_never_written_or_logged(job, monkeypatch, capsys, caplog):
    monkeypatch.setenv("ANTHROPIC_API_KEY", WORDS)
    job.save()
    assert job.run(FakeTransport([scripted(), scripted()])) == 0
    job.state.unlink()
    job.add(2, '"Next 20%"')
    job.save()
    assert job.run(FakeTransport([FatalApiError(WORDS)])) == 3
    for path in [job.state, job.summary, job.summary.with_suffix(".md"), *job.cache.rglob("*.json")]:
        assert WORDS not in path.read_text(encoding="utf-8")
    captured = capsys.readouterr()
    assert WORDS not in captured.err + captured.out + caplog.text


def test_4_14_missing_key_and_offline_dry_run(job, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    job.save()
    assert job.run(None) == 5
    assert job.run(None, "--dry-run") == 0
    assert not job.state.exists()
    assert not job.cache.exists()
    assert read(job.workset)["units"][0]["reviewStatus"] == "pending"
