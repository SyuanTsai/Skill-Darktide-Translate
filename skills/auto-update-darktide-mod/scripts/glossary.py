"""解析版本化詞彙表，保留來源行及標題以支援範圍判斷。"""

import re
from dataclasses import dataclass


BULLET = re.compile(r"^([ \t]*)[-*]\s+(.+?)\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
ANNOTATION = re.compile(r"（[^（）]*）|\([^()]*\)")
HAN = re.compile(r"[\u3400-\u9fff]")


def normalize(text):
    return " ".join(text.casefold().split())


@dataclass(frozen=True)
class Entry:
    aliases: tuple
    translation: str
    line: str
    headings: tuple
    contextual: bool


class Glossary:
    def __init__(self, entries):
        self.entries = entries
        self.by_alias = {}
        for entry in entries:
            for alias in entry.aliases:
                self.by_alias.setdefault(normalize(alias), []).append(entry)
        aliases = sorted(self.by_alias, key=len, reverse=True)
        self.pattern = re.compile("|".join(
            rf"(?<!\w){re.escape(alias)}(?:es|s)?(?!\w)" for alias in aliases
        )) if aliases else None

    @classmethod
    def parse(cls, text):
        headings = []
        entries = []
        parent = None
        for line in text.splitlines():
            if heading := HEADING.match(line):
                level = len(heading[1])
                while headings and headings[-1][0] >= level:
                    headings.pop()
                headings.append((level, heading[2]))
                parent = None
                continue
            bullet = BULLET.match(line)
            if not bullet:
                if line.strip():
                    parent = None
                continue
            indent, content = len(bullet[1].expandtabs(4)), bullet[2]
            parts = content.split(" - ")
            contextual = False
            source_line = line
            if len(parts) > 1 and HAN.search(parts[-1]):
                aliases, translation = parts[:-1], parts[-1]
                parent = None
            elif parent and indent > parent[0] and HAN.search(content):
                aliases, translation = parent[1], content
                contextual = True
                source_line = parent[2] + "\n" + line
            elif not HAN.search(content) and re.search(r"[a-zA-Z]", content):
                parent = (indent, [content], line)
                continue
            else:
                parent = None
                continue

            aliases = tuple(alias.strip().strip("‘’“”\u0060") for alias in aliases)
            target = ANNOTATION.sub("", translation).strip()
            if all(aliases) and target:
                contextual |= target != translation.strip() or bool(re.search(r"[/／]", target))
                entries.append(Entry(aliases, target, source_line,
                                     tuple(title for _, title in headings), contextual))
        return cls(entries)

    def groups(self, text):
        if self.pattern is None:
            return
        for match in self.pattern.finditer(normalize(text)):
            key = match[0]
            for candidate in (key, key.removesuffix("s"), key.removesuffix("es")):
                if candidate in self.by_alias:
                    yield self.by_alias[candidate]
                    break

    def match(self, text):
        return list(dict.fromkeys(entry for group in self.groups(text) for entry in group))

    def slice(self, sources):
        entries = dict.fromkeys(entry for text in sources for entry in self.match(text))
        return [{"section": list(entry.headings), "line": entry.line} for entry in entries]
