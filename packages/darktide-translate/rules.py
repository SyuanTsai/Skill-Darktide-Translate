"""從共用 manifest 建立規則與詞彙表的位元組綁定。"""

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path, PurePosixPath
import math
import re
import subprocess

from claude_runner.state import read_json


SKILL_REPO = Path(__file__).resolve().parents[2]
SKILL_ROOT = SKILL_REPO / "skills/auto-update-darktide-mod"
ASSETS_RELATIVE = (SKILL_ROOT / "assets").relative_to(SKILL_REPO).as_posix()
PROMPT_PATHS = {role: f"{ASSETS_RELATIVE}/api-{role}-prompt.md" for role in ("translator", "reviewer")}
GLOSSARY = "Referneces/Translation.md"
MODES = ("update", "improve")


def relative_path(value):
    if not isinstance(value, str):
        raise ValueError("需要 POSIX 相對路徑。")
    path = PurePosixPath(value)
    if (not path.parts or path.is_absolute() or ".." in path.parts or path.as_posix() != value
            or any(char in value for char in "\\:\t\r\n\0")):
        raise ValueError("需要 POSIX 相對路徑。")
    return path


def read_repository_file(root, path):
    location = (root / relative_path(path)).resolve()
    if not location.is_relative_to(root.resolve()):
        raise ValueError("規則或詞彙表超出來源儲存庫。")
    return location.read_bytes()


def read_repository_blob(root, base_oid, path):
    location = relative_path(path)
    result = subprocess.run(
        ["git", "-C", str(root), "cat-file", "blob", f"{base_oid}:{location.as_posix()}"],
        stdin=subprocess.DEVNULL, capture_output=True,
    )
    if result.returncode:
        raise ValueError("無法讀取工作集基準版本的規則或詞彙表。")
    return result.stdout


def load_config():
    config = read_json(SKILL_ROOT / "assets/api-translation.json")
    positive = ("batchSize", "maxItemsPerRun", "requestTimeoutSeconds", "maxOutputTokens")
    nonnegative = ("maxCorrectionsPerItem", "maxApiRetries")
    effort_options = ("low", "medium", "high", "xhigh", "max")

    def numeric(value):
        return type(value) in (float, int) and math.isfinite(value) and value >= 0

    if (type(config["configVersion"]) is not int or config["configVersion"] != 1
            or not isinstance(config["model"], str) or not config["model"]
            or any(type(config[key]) is not int or config[key] <= 0 for key in positive)
            or any(type(config[key]) is not int or config[key] < 0 for key in nonnegative)
            or any(config["effort"][role] not in effort_options for role in ("translator", "reviewer"))
            or len(config["retryBackoffSeconds"]) != config["maxApiRetries"]
            or any(not numeric(seconds) for seconds in config["retryBackoffSeconds"])
            or any(not numeric(config["pricingUsdPerMTok"][key])
                   for key in ("input", "output", "cacheWrite", "cacheRead"))
            or not isinstance(config["pricingSource"], str)):
        raise ValueError("翻譯設定格式無效。")
    return config


@dataclass
class Rules:
    binding: dict
    glossary: bytes
    files: dict

    def system(self, role):
        prompt_path = PROMPT_PATHS[role]
        sections = [self.files["skill", prompt_path].decode("utf-8-sig").strip()]
        for (repo, path), content in self.files.items():
            if path.endswith(".md") and (repo != "skill" or path not in PROMPT_PATHS.values()):
                sections.append(f"## {repo}/{path}\n\n{content.decode('utf-8-sig').strip()}")
        return "\n\n".join(sections)


def load_rules(mods_root, mode, mod_path, config=None, *, base_oid=None):
    mod_name = relative_path(mod_path).name
    if mode not in MODES:
        raise ValueError("翻譯模式無效。")
    if base_oid is not None and not re.fullmatch(r"[0-9a-f]{40}", base_oid):
        raise ValueError("工作集基準版本的 Git OID 無效。")
    if config is None:
        config = load_config()

    manifest = read_json(SKILL_ROOT / "assets/api-rules-manifest.json")
    if manifest["manifestVersion"] != 1:
        raise ValueError("規則 manifest 版本無效。")
    roots = {"skill": SKILL_REPO, "mods": mods_root}
    selected = set()
    for spec in manifest["files"]:
        mod_filter = spec["modFilter"]
        if mode in spec["modes"] and (mod_filter is None or mod_filter.casefold() == mod_name.casefold()):
            key = spec["repo"], spec["path"]
            if key in selected:
                raise ValueError("規則 manifest 有重複項目。")
            selected.add(key)

    def read_file(repo, path):
        if repo == "mods" and base_oid is not None:
            return read_repository_blob(mods_root, base_oid, path)
        return read_repository_file(roots[repo], path)

    files = {(repo, path): read_file(repo, path) for repo, path in sorted(selected)}
    rows = [{"repo": repo, "path": path, "sha256": sha256(data).hexdigest()}
            for (repo, path), data in files.items()]
    payload = "".join(f"{row['repo']}\t{row['path']}\t{row['sha256']}\n" for row in rows)
    glossary = read_file("mods", GLOSSARY)
    binding = {
        "bindingVersion": 1,
        "mode": mode,
        "modelId": config["model"],
        "rulesSha256": sha256(payload.encode("utf-8")).hexdigest(),
        "glossarySha256": sha256(glossary).hexdigest(),
        "rulesManifest": rows,
    }
    return Rules(binding, glossary, files)
