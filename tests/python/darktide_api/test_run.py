import copy
import hashlib
import json
from pathlib import Path
import subprocess

import pytest

from claude_runner.client import FakeTransport, FatalApiError, Response, RetryableApiError
from claude_runner.state import State
from checks import Luac
from darktide_translate import main
from rules import SKILL_ROOT, load_config, load_rules

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


def scripted(translation="增加15%", *, model=MODEL, issues=(), unknown=(), lookup=False, reject=False):
    def respond(request):
        units = request.user["units"]
        if request.role == "translator":
            items = [{"unitId": unit["unitId"], "segments": {"s1": translation},
                      "unknownTerms": list(unknown), "needsLookupDefinition": lookup}
                     for unit in units]
        else:
            items = [{"unitId": unit["unitId"], "verdict": "fail" if issues or reject else "pass",
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


# Scenario: Another workset supplies different previous English or upstream zh-tw for the same new text.
# Purpose: Re-review candidates when their source history or translation context changes.
@pytest.mark.parametrize(("side", "field", "value"), [
    ("old", "sourceExpression", '"Raise by 10%"'),
    ("new", "zhTwExpression", '"提高15%"'),
])
def test_InterT08_cache_isolated_by_candidate_context(job, side, field, value):
    job.save()
    assert job.run(FakeTransport([scripted(), scripted()])) == 0

    unit = job.doc["units"][0]
    unit[side][field]["raw"] = value
    job.doc["immutableContractSha256"] = "b" * 64
    job.save()
    assert job.run(FakeTransport([])) == 4
    job.state.unlink()
    transport = FakeTransport([scripted("提高15%"), scripted()])

    assert job.run(transport) == 0
    assert [request.role for request in transport.requests] == ["translator", "reviewer"]
    assert read(job.summary)["cacheHitCount"] == 0
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == '"提高15%"'


# Scenario: A fresh workset changes its new English, bound rules, or requested model.
# Purpose: Keep the adapter from resuming or reusing an approval across these boundaries.
@pytest.mark.parametrize("changed", ["source", "rules", "model"])
def test_InterT09_workset_change_isolates_state_and_cache(job, monkeypatch, changed):
    job.save()
    assert job.run(FakeTransport([scripted(), scripted()])) == 0

    config = load_config()
    if changed == "source":
        job.doc["units"][0]["new"]["sourceExpression"]["raw"] = '"Boost 15%"'
    elif changed == "rules":
        rule = next(row for row in job.doc["translationBinding"]["rulesManifest"] if row["repo"] == "mods")
        (job.mods / rule["path"]).write_bytes(b"Changed sample rules\r\n")
    else:
        config["model"] = "mock-replacement-model"
        monkeypatch.setattr("darktide_translate.load_config", lambda: config)
    job.doc["translationBinding"] = load_rules(job.mods, "update", "mods/TestMod", config).binding
    job.doc["immutableContractSha256"] = "b" * 64
    job.save()

    assert job.run(FakeTransport([])) == 4
    job.state.unlink()
    reply = scripted("提高15%", model=config["model"])
    transport = FakeTransport([reply, reply])
    assert job.run(transport) == 0
    assert [request.role for request in transport.requests] == ["translator", "reviewer"]
    assert read(job.summary)["cacheHitCount"] == 0
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == '"提高15%"'


# Scenario: The translator flags terms in a translation that passes both checks.
# Purpose: Keep the adopted text and terms available after API, resume, and cache paths.
def test_InterT10_unknown_terms_follow_the_approved_translation(job):
    unit = job.doc["units"][0]
    unit["new"]["sourceExpression"]["raw"] = '"Shot Recovery"'
    job.save()
    flagged = ["Shot Recovery"]
    expected = {"unitId": unit["unitId"], "key": unit["key"], "source": '"Shot Recovery"',
                "terms": flagged, "translation": '"射擊恢復"'}

    assert job.run(FakeTransport([scripted("射擊恢復", unknown=flagged), scripted()])) == 0
    record = read(job.state)["units"][unit["unitId"]]
    assert record["status"] == "approved"
    assert record["unknownTerms"] == flagged
    assert record["key"] == expected["key"] and record["source"] == expected["source"]
    assert record["expression"] == expected["translation"]
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == expected["translation"]
    assert read(job.summary)["unknownTerms"] == [expected]
    assert read(job.summary)["blocked"] == []
    markdown = job.summary.with_suffix(".md").read_text(encoding="utf-8")
    assert "### 待確認術語\n\n- demo — Shot Recovery" in markdown
    assert "### BLOCKED 項目" not in markdown

    job.save()
    assert job.run(FakeTransport([])) == 0
    assert read(job.summary)["unknownTerms"] == [expected]

    job.state.unlink()
    unit.update(unitId="testmod :: $ :: cached :: 1", key="cached")
    job.save()
    assert job.run(FakeTransport([])) == 0
    assert read(job.summary)["cacheHitCount"] == 1
    assert read(job.summary)["unknownTerms"] == [{**expected, "unitId": unit["unitId"], "key": unit["key"]}]


# Scenario: The model returns straight or curly double quotes around its text.
# Purpose: Send corrected text to the reviewer and writeback while preserving source quotes.
@pytest.mark.parametrize(("source", "translation", "adopted", "warned"), [
    ('"Gain 15%"', '"增加15%"', "增加15%", True),
    ('"Gain 15%"', '“增加15%”', "增加15%", True),
    ('"Gain 15%"', ' ＂增加15%＂ ', " 增加15% ", True),
    (r'"\"Gain 15%\""', '"增加15%"', '"增加15%"', False),
    ('"“Gain 15%”"', '"增加15%"', '"增加15%"', False),
    ('"Gain 15%"', '"增加" "15%"', '"增加" "15%"', False),
])
def test_InterT20_unexpected_outer_double_quotes_are_removed_before_review(job, source, translation, adopted, warned):
    unit = job.doc["units"][0]
    unit["new"]["sourceExpression"]["raw"] = source
    job.save()
    transport = FakeTransport([scripted(translation), scripted()])

    assert job.run(transport) == 0
    assert transport.requests[1].user["units"][0]["translation"] == {"s1": adopted}
    record = read(job.state)["units"][unit["unitId"]]
    output = read(job.workset)["units"][0]
    assert output["reviewStatus"] == "approved"
    assert output["suggestedZhTwExpression"] == json.dumps(adopted, ensure_ascii=False)
    warning = "unexpected_outer_double_quotes"
    assert record["warnings"] == ([warning] if warned else [])
    report = read(job.summary)
    assert report["warnings"] == ([{"unitId": unit["unitId"], "code": warning}] if warned else [])
    assert report["blocked"] == []
    assert (warning in job.summary.with_suffix(".md").read_text(encoding="utf-8")) == warned


# Scenario: A flagged translation has extra quotes and changes an English placeholder.
# Purpose: Required structural checks still block the item after exhausting corrections.
def test_InterT30_placeholder_mismatch_still_blocks_a_flagged_translation(job):
    unit = job.doc["units"][0]
    unit["new"]["sourceExpression"]["raw"] = '"Gain {amount}"'
    job.save()
    bad_translation = scripted('"增加{other}"', unknown=["Gain"])

    assert job.run(FakeTransport([bad_translation] * 3)) == 0
    record = read(job.state)["units"][unit["unitId"]]
    assert record["feedback"] == ["placeholder_mismatch"]
    report = read(job.summary)
    assert report["blocked"] == [{"unitId": unit["unitId"], "reason": "max_corrections_reached"}]
    assert report["unknownTerms"] == []
    assert read(job.workset)["units"][0]["reviewStatus"] == "pending"


# Scenario: A lookup-marked reply passes review, has no usable text, or only fails term review.
# Purpose: Report the lookup and adopt reviewed text, compatible zh-tw, or the exact English expression.
@pytest.mark.parametrize(("candidate", "previous", "translation", "review_issue", "adopted", "adoption"), [
    (None, None, "替代貼花%s\n{#color(1,2,3)}%d{#reset()}", None,
     r'"替代貼花%s\n{#color(1,2,3)}%d{#reset()}"', "translation"),
    (r"'現有貼花%s\n{#color(1,2,3)}%d{#reset()}'", None, "", None,
     r"'現有貼花%s\n{#color(1,2,3)}%d{#reset()}'", "existing_zh_tw"),
    ('""', r'"舊譯%d\n{#color(1,2,3)}%s{#reset()}"', "", None,
     r'"Alt decal%s\n{#color(1,2,3)}%d{#reset()}"', "english_fallback"),
    ('""', r'"舊版貼花%s\n{#color(1,2,3)}%d{#reset()}"', "", None,
     r'"舊版貼花%s\n{#color(1,2,3)}%d{#reset()}"', "existing_zh_tw"),
    (None, None, "替代貼花%s\n{#color(1,2,3)}%d{#reset()}", "term",
     r'"Alt decal%s\n{#color(1,2,3)}%d{#reset()}"', "english_fallback"),
])
def test_InterT35_lookup_uses_safe_adoption(job, candidate, previous, translation, review_issue, adopted, adoption):
    unit = job.doc["units"][0]
    source = r'"Alt decal%s\n{#color(1,2,3)}%d{#reset()}"'
    unit["new"]["sourceExpression"]["raw"] = source
    for side, existing in (("new", candidate), ("old", previous)):
        unit[side]["zhTwExpression"] = {"raw": existing} if existing is not None else None
    job.save()
    translate = scripted(translation, lookup=True, unknown=["Alt decal"])
    review = scripted(issues=[{"category": review_issue, "detail": "Alt decal"}] if review_issue else [])
    replies = [translate] if not translation else [translate, review] * (3 if review_issue else 1)
    transport = FakeTransport(replies)

    assert job.run(transport) == 0
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == adopted
    report = read(job.summary)
    assert report["blocked"] == []
    reason = "max_corrections_reached" if review_issue else "needs_lookup_definition"
    expected = {"unitId": unit["unitId"], "key": unit["key"], "source": source,
                "terms": ["Alt decal"], "translation": adopted, "reason": reason, "adoption": adoption}
    if review_issue:
        expected["lastFailure"] = [{"category": review_issue, "detail": "Alt decal"}]
    assert report["termReviews"] == [expected]
    markdown = job.summary.with_suffix(".md").read_text(encoding="utf-8")
    assert reason in markdown and "Alt decal" in markdown
    job.save()
    assert job.run(FakeTransport([])) == 0
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == adopted


# Scenario: An opaque call contains text that the adapter cannot safely rewrite.
# Purpose: Record the untranslated fragment and leave the upstream field bytes alone.
@pytest.mark.parametrize("existing", [None, '"上游譯文"'])
def test_InterT36_opaque_lua_expression_is_preserved(job, existing):
    unit = job.doc["units"][0]
    source = 'Localize("loc_zone_expeditions") .. helper(" Expedition: %s")'
    unit["new"]["sourceExpression"]["raw"] = source
    unit["new"]["zhTwExpression"] = {"raw": existing} if existing else None
    job.save()

    assert job.run(FakeTransport([])) == 0
    output = read(job.workset)["units"][0]
    assert output["reviewStatus"] == "preserved"
    assert output["suggestedZhTwExpression"] is None
    report = read(job.summary)
    assert report["blocked"] == []
    assert report["termReviews"] == [{"unitId": unit["unitId"], "key": unit["key"], "source": source,
                                      "terms": ["Expedition: %s"], "translation": existing or source,
                                      "reason": "complex_expression", "adoption": "preserved_expression"}]


# Scenario: The proposed text repeatedly changes a literal gameplay value.
# Purpose: Keep the exact English value and expose the deterministic failure in term review.
def test_InterT37_exhausted_numeric_text_mismatch_is_reported(job):
    job.save()
    assert job.run(FakeTransport([scripted("增加10%")] * 3)) == 0
    report = read(job.summary)
    assert report["blocked"] == []
    assert report["termReviews"][0]["lastFailure"] == ["number_mismatch"]
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == '"Gain 15%"'


# Scenario: Corrections end with a semantic rejection, including a previously blocked state.
# Purpose: Adopt compatible existing zh-tw or exact English and report the last failure without caching.
@pytest.mark.parametrize(("existing", "adoption"), [
    (r"'現有貼花{amount}%s\n{#color(1,2,3)}%d{#reset()}'", "existing_zh_tw"),
    (r'"舊版貼花{amount}%d\n{#color(1,2,3)}%s{#reset()}"', "english_fallback"),
])
@pytest.mark.parametrize("legacy", [False, True])
def test_InterT38_exhausted_text_corrections_use_safe_fallback(job, existing, adoption, legacy):
    unit = job.doc["units"][0]
    unit_id = unit["unitId"]
    source = r'"Alt decal{amount}%s\n{#color(1,2,3)}%d{#reset()}"'
    adopted = existing if adoption == "existing_zh_tw" else source
    unit["new"]["sourceExpression"]["raw"] = source
    unit["new"]["zhTwExpression"] = None
    unit["old"]["zhTwExpression"] = {"raw": existing}
    feedback = [{"category": "meaning", "detail": "貼花功能的語意有誤"}]
    translation = scripted("替代貼花{amount}%s\n{#color(1,2,3)}%d{#reset()}")
    review = scripted(issues=feedback)
    job.save()
    if legacy:
        # Seed a v0.7.0 terminal state with the same immutable workset binding.
        binding = job.doc["translationBinding"]
        identity = {"worksetSha256": job.doc["immutableContractSha256"],
                    "rulesSha": binding["rulesSha256"], "glossarySha": binding["glossarySha256"],
                    "mode": binding["mode"], "model": binding["modelId"]}
        State(job.state, identity).set_unit(unit_id, {
            "status": "blocked", "blockedReason": "max_corrections_reached",
            "attempts": 3, "corrections": 2, "feedback": feedback,
        })

    transport = FakeTransport([] if legacy else [translation, review] * 3)
    assert job.run(transport) == 0
    output = read(job.workset)["units"][0]
    assert (output["reviewStatus"], output["suggestedZhTwExpression"]) == ("approved", adopted)
    report = read(job.summary)
    assert report["blocked"] == []
    assert report["termReviews"] == [{"unitId": unit_id, "key": unit["key"], "source": source,
                                      "terms": [], "translation": adopted, "lastFailure": feedback,
                                      "reason": "max_corrections_reached", "adoption": adoption}]
    assert "貼花功能的語意有誤" in job.summary.with_suffix(".md").read_text(encoding="utf-8")
    assert list(job.cache.rglob("*.json")) == []
    assert len(transport.requests) == (0 if legacy else 6)
    job.save()
    assert job.run(FakeTransport([])) == 0
    assert read(job.summary)["termReviews"] == report["termReviews"]


# Scenario: The reviewer rejects structurally valid text without supplying issues.
# Purpose: Use a safe fallback and identify the missing reviewer detail in the summary.
def test_InterT39_review_rejection_without_detail_is_reported(job):
    job.save()
    assert job.run(FakeTransport([scripted(), scripted(reject=True)] * 3)) == 0
    report = read(job.summary)
    assert report["blocked"] == []
    assert report["termReviews"][0]["lastFailure"] == ["review_rejected_without_detail"]
    assert read(job.workset)["units"][0]["suggestedZhTwExpression"] == '"Gain 15%"'


# Scenario: Source Lua is invalid, or a candidate still violates a structural check.
# Purpose: Leave invalid items pending even when the model marks them as needing lookup.
@pytest.mark.parametrize(("source", "translation", "issue"), [
    ('"Gain %d"', "增加%s", "format_order_mismatch"),
    ('Localize("key") ..', None, "invalid_lua_expression"),
])
def test_InterT40_blocked_remains_pending(job, source, translation, issue):
    unit = job.doc["units"][0]
    unit["new"]["sourceExpression"]["raw"] = source
    job.save()
    replies = [scripted(translation, lookup=True)] * 3 if translation else []
    assert job.run(FakeTransport(replies)) == 0
    report = read(job.summary)
    record = read(job.state)["units"][unit["unitId"]]
    if translation:
        assert issue in record["feedback"]
    assert report["blocked"][0]["reason"] == ("max_corrections_reached" if translation else issue)
    assert report["termReviews"] == []
    assert read(job.workset)["units"][0]["reviewStatus"] == "pending"
    assert list(job.cache.rglob("*.json")) == []
    assert job.run(FakeTransport([])) == 0
    assert read(job.summary)["blocked"] == report["blocked"]


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


# Scenario: A changed English source with existing zh-tw is sent for translation and review.
# Purpose: Verify the two roles receive their own prompt, schema and inputs, with usage recorded separately.
def test_InterT50_translation_and_review_request_shape_and_usage(job):
    job.save()
    transport = FakeTransport([scripted(), scripted()])
    assert job.run(transport) == 0
    translator, reviewer = transport.requests
    assert (translator.role, reviewer.role) == ("translator", "reviewer")
    unit = job.doc["units"][0]
    shared = {"mode": "update", "glossarySha256": job.doc["translationBinding"]["glossarySha256"],
              "glossary": []}
    source = {"unitId": unit["unitId"], "source": {"s1": "Gain 15%"}}
    assert translator.user == {**shared, "units": [{**source, "key": unit["key"],
        "containerPath": unit["containerPath"], "previousEnglish": '"Gain 10%"',
        "previousZhTw": '"增加10%"', "candidateZhTw": '"增加10%"', "feedback": []}]}
    assert reviewer.user == {**shared, "units": [{**source, "translation": {"s1": "增加15%"}}]}
    assert {"unitId", "segments", "unknownTerms", "needsLookupDefinition"} == set(
        translator.schema["properties"]["items"]["items"]["required"])
    assert {"unitId", "verdict", "issues"} == set(reviewer.schema["properties"]["items"]["items"]["required"])
    for request in transport.requests:
        assert request.model == MODEL and request.effort == "medium"
        assert request.max_tokens == 32000
        assert "Sample rules" in request.system
        prompt = SKILL_ROOT / f"assets/api-{request.role}-prompt.md"
        assert request.system.startswith(prompt.read_text(encoding="utf-8-sig").strip())
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
