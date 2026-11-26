"""工作集選取與僅替換審查欄位的原子回填。"""

import codecs
import json
import re

from claude_runner.state import atomic_text


WHITESPACE = re.compile(r"[ \r\n\t]*")
DIGEST = re.compile(r"[a-f0-9]{64}")


class WorksetError(ValueError):
    pass


class Workset:
    def __init__(self, path):
        self.path = path
        self.snapshot = path.read_bytes()
        self.text = self.snapshot.decode("utf-8-sig")
        self.document = json.loads(self.text)
        doc = self.document
        if (not isinstance(doc, dict) or doc.get("status") != "ready"
                or type(doc.get("schemaVersion")) is not int or doc["schemaVersion"] != 1
                or type(doc.get("workflowSchemaVersion")) is not int or doc["workflowSchemaVersion"] != 15):
            raise WorksetError("工作集必須是 ready 的 Schema 1／15。")
        if "translationBinding" not in doc:
            raise WorksetError("工作集缺少 translationBinding，請用新版工作集產生器重建。")
        if not isinstance(doc.get("immutableContractSha256"), str) or not DIGEST.fullmatch(
                doc["immutableContractSha256"]):
            raise WorksetError("工作集缺少有效的不可變契約雜湊。")

        self.units = doc["units"]
        if not isinstance(self.units, list):
            raise WorksetError("工作集 units 必須是陣列。")
        ids = [unit["unitId"] for unit in self.units]
        if any(not isinstance(unit_id, str) or not unit_id for unit_id in ids) or len(ids) != len(set(ids)):
            raise WorksetError("工作集 unitId 必須有效且唯一。")
        self.pending = {}
        for unit in self.units:
            if unit["action"] == "AI_REQUIRED" and unit["reviewStatus"] == "pending":
                if "suggestedZhTwExpression" not in unit or unit["suggestedZhTwExpression"] is not None:
                    raise WorksetError("待翻譯項目的 suggestedZhTwExpression 必須是 null。")
                self.pending[unit["unitId"]] = unit

    def bind(self, expected):
        binding = self.document["translationBinding"]
        if (not isinstance(binding, dict) or type(binding.get("bindingVersion")) is not int
                or binding != expected):
            raise WorksetError("工作集綁定與目前模式、模型、規則或詞彙表不符，請用新版產生器重建。")
        return binding

    def fill(self, approvals):
        if not approvals:
            return
        if self.path.read_bytes() != self.snapshot:
            raise WorksetError("工作集在翻譯期間已變更，請重新執行以接續。")

        # 保留各未回填項的原始 UTF-8 內容、行尾和整份 JSON 的鍵順序。
        fields = dict(object_fields(self.text, WHITESPACE.match(self.text).end()))
        position = WHITESPACE.match(self.text, fields["units"][0] + 1).end()
        edits = []
        decoder = json.JSONDecoder()
        for unit in self.units:
            _, end = decoder.raw_decode(self.text, position)
            if unit["unitId"] in approvals:
                fields = dict(object_fields(self.text, position))
                status, expression = approvals[unit["unitId"]]
                for name, value in (("reviewStatus", status), ("suggestedZhTwExpression", expression)):
                    start, finish = fields[name]
                    edits.append((start, finish, json.dumps(value, ensure_ascii=False)))
            position = WHITESPACE.match(self.text, end).end() + 1
            position = WHITESPACE.match(self.text, position).end()

        output = []
        position = 0
        for start, end, replacement in sorted(edits):
            output += [self.text[position:start], replacement]
            position = end
        bom = "\ufeff" if self.snapshot.startswith(codecs.BOM_UTF8) else ""
        atomic_text(self.path, bom + "".join(output) + self.text[position:])


def object_fields(text, start):
    decoder = json.JSONDecoder()
    position = WHITESPACE.match(text, start + 1).end()
    while text[position] != "}":
        key, end = decoder.raw_decode(text, position)
        value_start = WHITESPACE.match(text, WHITESPACE.match(text, end).end() + 1).end()
        _, value_end = decoder.raw_decode(text, value_start)
        yield key, (value_start, value_end)
        position = WHITESPACE.match(text, value_end).end()
        if text[position] == ",":
            position = WHITESPACE.match(text, position + 1).end()


def expression(unit, side, field):
    record = (unit[side] or {}).get(field)
    value = record["raw"] if record is not None else None
    if value is not None and not isinstance(value, str):
        raise WorksetError("工作集 expression.raw 必須是字串。")
    return value
