"""模型文字回填前的可重現結構檢查與選用 Lua 語法檢查。"""

import re
import shutil
import subprocess
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

from lua_template import safe_text


PRINTF = r"%(?:%|[-+ #0]*\d*(?:\.\d+)?[cdiouxXeEfgGqs])"
PLACEHOLDER = re.compile(r"\{[A-Za-z_][\w.]*(?::[^{}\n]+)?\}|" + PRINTF)
FORMAT = re.compile(PRINTF)
MARKUP = re.compile(r"\{#([a-zA-Z_]\w*)\([^{}\n]*\)\}")
NUMBER = re.compile(r"[+-]?\d+(?:\.\d+)?%?")


class Luac:
    def __init__(self, executable, runner=subprocess.run):
        self.executable = executable
        self.runner = runner

    @classmethod
    def discover(cls):
        return cls(shutil.which("luac"))

    @property
    def available(self):
        return self.executable is not None

    def accepts(self, expression):
        if not self.available:
            return True
        with TemporaryDirectory() as directory:
            path = Path(directory) / "expression.lua"
            path.write_text(f"return {{ x = {expression} }}\n", encoding="utf-8", newline="\n")
            try:
                process = self.runner([str(self.executable), "-p", str(path)],
                                      capture_output=True, check=False, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                return False
            return process.returncode == 0


def markup_shape(text):
    tags = list(MARKUP.finditer(text))
    depth = 0
    paired = True
    for tag in tags:
        name = tag[1]
        if name == "reset":
            depth -= 1
            paired &= depth >= 0
        elif name == "color":
            depth += 1
    paired &= depth == 0
    complete = text.count("{#") == len(tags)
    return [tag[0] for tag in tags], paired and complete


def validate(template, segments, glossary, luac):
    if not isinstance(segments, dict) or segments.keys() != template.segments.keys():
        return None, ["segment_mismatch"]
    if any(not isinstance(text, str) or not safe_text(text) for text in segments.values()):
        return None, ["invalid_control_character"]

    source = "".join(template.segments.values())
    target = "".join(segments[key] for key in template.segments)
    issues = []
    if Counter(PLACEHOLDER.findall(source)) != Counter(PLACEHOLDER.findall(target)):
        issues.append("placeholder_mismatch")
    if template.has_format and FORMAT.findall(source) != FORMAT.findall(target):
        issues.append("format_order_mismatch")
    source_markup, source_paired = markup_shape(source)
    target_markup, target_paired = markup_shape(target)
    if source_markup != target_markup or (source_paired and not target_paired):
        issues.append("markup_mismatch")
    if source.count("\n") != target.count("\n"):
        issues.append("newline_mismatch")
    if Counter(NUMBER.findall(source)) != Counter(NUMBER.findall(target)):
        issues.append("number_mismatch")
    for group in glossary.groups(" ".join(template.segments.values())):
        translations = {entry.translation for entry in group}
        if len(translations) == 1 and not any(entry.contextual for entry in group):
            if not any(term in target for term in translations):
                issues.append("glossary_term_missing")
                break

    try:
        expression = template.render(segments)
    except ValueError as error:
        return None, [*issues, str(error)]
    if not luac.accepts(expression):
        issues.append("luac_syntax_error")
    return expression, issues
