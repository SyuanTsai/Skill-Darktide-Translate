"""Verify per-unit gameplay references against a local Mods Git object."""

from hashlib import sha256
import json
import os
import re
import subprocess

from rules import relative_path
from workset import WorksetError, expression


MISSING = "gameplay_context_missing"
INVALID = "gameplay_context_invalid"
INSUFFICIENT = "gameplay_context_insufficient"
CHATBLOCK_RELOAD_KEY = "auto_melee_swap_wait_for_reload_tooltip"
OID = re.compile(r"[a-f0-9]{40}")
MAX_BLOB_BYTES = 1024 * 1024
MAX_SIDECAR_BYTES = 256 * 1024
MAX_REFERENCES = 4
MAX_EXCERPT_LINES = 120
MAX_EXCERPT_BYTES = 8192


def fingerprint(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")).hexdigest()


def git(root, *args):
    result = subprocess.run(
        ["git", "--no-replace-objects", "--literal-pathspecs", "-C", str(root), *args],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=10,
        env={**os.environ, "GIT_NO_LAZY_FETCH": "1"},
    )
    if result.returncode:
        raise ValueError("Git object unavailable")
    return result.stdout


def lua_path(value, mod_path):
    path = relative_path(value)
    if (mod_path.parts[:-1] not in (("Warhammer 40,000 DARKTIDE", "mods"), ("mods",))
            or mod_path not in path.parents or path.suffix != ".lua"
            or any(ord(char) < 32 for char in value) or any(part.lower() == ".git" for part in path.parts)):
        raise ValueError("Lua path outside the MOD")
    return path


class Candidate:
    def __init__(self, root, document, entry):
        self.root = root
        self.mod_path = relative_path(document["modRelativePath"])
        self.oid = entry["candidateOid"]
        if not OID.fullmatch(self.oid) or git(root, "cat-file", "-t", self.oid).strip() not in (b"commit", b"tree"):
            raise ValueError("Expected a local Git commit or tree OID")
        self.localization_path = lua_path(entry["localizationPath"], self.mod_path)
        if not self.localization_path.name.lower().endswith("_localization.lua"):
            raise ValueError("Expected a localization file")
        self.localization = self.blob(self.localization_path)
        self.localization_sha = sha256(self.localization).hexdigest()
        if self.localization_sha != document["new"]["sha256"]:
            raise ValueError("Localization differs from the candidate")

    def blob(self, path):
        listing = git(self.root, "ls-tree", "-z", "--full-tree", self.oid, "--", str(path))
        metadata, separator, name = listing.partition(b"\t")
        mode, kind, oid = metadata.decode("ascii").split()
        if (not separator or name != str(path).encode("utf-8") + b"\0"
                or mode not in ("100644", "100755") or kind != "blob" or not OID.fullmatch(oid)):
            raise ValueError("Expected a regular Lua blob")
        if int(git(self.root, "cat-file", "-s", oid)) > MAX_BLOB_BYTES:
            raise ValueError("Lua blob exceeds the size limit")
        return git(self.root, "cat-file", "blob", oid)

    def evidence(self, unit, row):
        record = unit["new"]
        raw = expression(unit, "new", "sourceExpression").encode("utf-8")
        span = record["sourceExpression"]
        start, length = span["startByte"], span["lengthByte"]
        if (row["key"] != unit["key"] or not unit["key"] or record["key"] != unit["key"]
                or record["unitId"] != unit["unitId"] or type(start) is not int or type(length) is not int
                or start < 0 or not raw or length != len(raw) or self.localization[start:start + length] != raw):
            raise ValueError("Reference does not match the exact candidate unit")

        references = row["references"]
        if not isinstance(references, list) or len(references) > MAX_REFERENCES:
            raise ValueError("Invalid number of references")
        files, excerpts = {}, []
        total_lines = total_bytes = 0
        for reference in references:
            path = lua_path(reference["path"], self.mod_path)
            if path.name.lower().endswith("_localization.lua"):
                raise ValueError("Expected a runtime file")
            if path not in files:
                files[path] = (self.blob(path).removesuffix(b"\n").split(b"\n"), set())
            lines, selected = files[path]
            first, last = reference["startLine"], reference["endLine"]
            if (type(first) is not int or type(last) is not int or not 1 <= first <= last <= len(lines)
                    or total_lines + last - first + 1 > MAX_EXCERPT_LINES):
                raise ValueError("Invalid line range")
            span_lines = set(range(first, last + 1))
            if selected & span_lines or len(selected | span_lines) == len(lines):
                raise ValueError("Overlapping ranges or complete runtime file")
            selected.update(span_lines)
            total_lines += len(span_lines)
            excerpt = b"\n".join(line.removesuffix(b"\r") for line in lines[first - 1:last])
            total_bytes += len(excerpt)
            if total_bytes > MAX_EXCERPT_BYTES or not excerpt.strip() or b"\0" in excerpt:
                raise ValueError("Invalid excerpt contents or size")
            excerpts.append({"path": str(path), "startLine": first, "endLine": last,
                             "excerpt": excerpt.decode("utf-8")})
        return {"candidateOid": self.oid, "localizationPath": str(self.localization_path),
                "localizationSha256": self.localization_sha, "references": excerpts}


def unique_fields(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("Duplicate context field")
    return result


def load_context(path, root, workset):
    units = {unit["unitId"]: unit for unit in workset.units if unit["action"] == "AI_REQUIRED"}
    required = {unit_id for unit_id, unit in units.items()
                if unit.get("key") == CHATBLOCK_RELOAD_KEY
                and relative_path(workset.document["modRelativePath"]).name.casefold() == "chatblock"}
    blocked = dict.fromkeys(required, MISSING)
    if path is None:
        return {}, blocked

    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_SIDECAR_BYTES + 1)
        if len(data) > MAX_SIDECAR_BYTES:
            raise ValueError("Sidecar exceeds the size limit")
        entry = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique_fields)
        rows = entry["units"]
        if (type(entry["version"]) is not int or entry["version"] != 1
                or not isinstance(rows, dict) or rows.keys() - units.keys()):
            raise ValueError("Invalid context contract")
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        raise WorksetError("遊戲脈絡檔無法讀取、格式無效或含有未知工作集項目。") from None

    if not rows:
        return {}, blocked
    verification_errors = (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.TimeoutExpired)
    try:
        candidate = Candidate(root, workset.document, entry)
    except verification_errors:
        blocked.update(dict.fromkeys(rows, INVALID))
        return {}, blocked

    contexts = {}
    for unit_id, row in rows.items():
        try:
            context = candidate.evidence(units[unit_id], row)
        except verification_errors:
            blocked[unit_id] = INVALID
            continue
        if context["references"]:
            blocked.pop(unit_id, None)
            contexts[unit_id] = {"key": units[unit_id]["key"], **context}
        else:
            blocked[unit_id] = MISSING
    return contexts, blocked
