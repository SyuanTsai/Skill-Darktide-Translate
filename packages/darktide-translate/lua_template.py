"""以來源 Lua token 建立單一 expression 的文字片段模板。"""

import re
from dataclasses import dataclass
from enum import Enum, auto
from unicodedata import category


class ComplexExpression(ValueError):
    pass


LONG_OPEN = re.compile(r"\[(=*)\[")
QUOTED = re.compile(r"""(?:"(?:\\(?:\r\n|[\s\S])|[^"\\])*"|'(?:\\(?:\r\n|[\s\S])|[^'\\])*')""")
LETTERS = {"Lu", "Ll", "Lt", "Lm", "Lo"}
OPERATORS = ("...", "..", "==", "~=", "<=", ">=", "//", "<<", ">>", "::")
SYMBOLS = frozenset("+-*/%^#&~|<>=(){}[];:,.")
KEYWORDS = frozenset(
    "and break do else elseif end false for function goto if in local nil not or repeat return then true until while".split()
)
PRECEDENCE = {
    "or": 1, "and": 2, "<": 3, ">": 3, "<=": 3, ">=": 3, "~=": 3, "==": 3,
    "|": 4, "~": 5, "&": 6, "<<": 7, ">>": 7, "..": 8,
    "+": 9, "-": 9, "*": 10, "/": 10, "//": 10, "%": 10, "^": 12,
}
NUMBER = re.compile(r"(?:0[xX][\da-fA-F]+(?:\.[\da-fA-F]*)?(?:[pP][+-]?\d+)?"
                    r"|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\Z")
SCANNER_NUMBER = re.compile(r"[A-Za-z0-9._]*")
DECIMAL_TAIL = re.compile(r"[0-9]+")


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int


def tokenize(text):
    tokens = []
    cursor = 0
    while cursor < len(text):
        char = text[cursor]
        if char.isspace():
            cursor += 1
            continue
        comment = text.startswith("--", cursor)
        long_open = LONG_OPEN.match(text, cursor + 2 if comment else cursor)
        if long_open:
            closing = f"]{long_open[1]}]"
            end = text.find(closing, long_open.end())
            if end < 0:
                raise ComplexExpression("Lua 長字串或長註解未閉合")
            end += len(closing)
            kind = "string"
        elif comment:
            newline = text.find("\n", cursor + 2)
            end, kind = newline + 1 if newline >= 0 else len(text), "comment"
        elif char in "\"'":
            match = QUOTED.match(text, cursor)
            if not match:
                raise ComplexExpression("Lua 引號未閉合")
            end, kind = match.end(), "string"
        elif char == "_" or category(char) in LETTERS:
            end = cursor + 1
            while end < len(text) and (text[end] == "_" or category(text[end]) in LETTERS | {"Nd"}):
                end += 1
            kind = "identifier"
        elif category(char) == "Nd":
            end = SCANNER_NUMBER.match(text, cursor + 1).end()
            kind = "number"
        elif char in SYMBOLS:
            operator = next((op for op in OPERATORS if text.startswith(op, cursor)), char)
            end, kind = cursor + len(operator), "symbol"
        else:
            raise ComplexExpression("Lua 含無法辨識的 token")
        if not comment:
            tokens.append(Token(kind, text[cursor:end], cursor, end))
        cursor = end
    return tokens


ESCAPES = dict(zip("abfnrtv\\\"'", "\a\b\f\n\r\t\v\\\"'"))
ESCAPE_PART = re.compile(r"\\(?:[0-9]{1,3}|x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|z\s*|\r\n|[\s\S])|[^\\]+")
NEWLINE = re.compile(r"\r\n|\n\r|\r|\n")


def decode_string(literal):
    first = LONG_OPEN.match(literal)
    if first:
        content = literal[first.end():-len(first[0])]
        return NEWLINE.sub("\n", content).removeprefix("\n")
    result = bytearray()
    for match in ESCAPE_PART.finditer(literal[1:-1]):
        part = match[0]
        if not part.startswith("\\"):
            if "\n" in part or "\r" in part:
                raise ComplexExpression("Lua 短字串含未逸出的換行")
            result.extend(part.encode("utf-8"))
            continue
        escaped = part[1:]
        if escaped in ESCAPES:
            result.extend(ESCAPES[escaped].encode())
        elif escaped in ("\n", "\r", "\r\n"):
            result.append(10)
        elif escaped.isdecimal() and escaped.isascii() and int(escaped) <= 255:
            result.append(int(escaped))
        elif len(escaped) == 3 and escaped.startswith("x"):
            result.append(int(escaped[1:], 16))
        elif escaped.startswith("u{"):
            result.extend(chr(int(escaped[2:-1], 16)).encode("utf-8"))
        elif not escaped.startswith("z"):
            raise ComplexExpression("Lua 字串含不支援的逸出序列")
    return result.decode("utf-8")


def safe_text(text):
    return all(ch in "\n\t" or category(ch) not in ("Cc", "Cs") for ch in text)


def quote(text):
    if not safe_text(text):
        raise ValueError("invalid_control_character")
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return '"' + escaped + '"'


FORMAT_CALLS = frozenset(("string.format", "format"))


class StringContext(Enum):
    TRANSLATABLE = auto()
    UNKNOWN_ARGUMENT = auto()
    INDEX = auto()


class Expression:
    """保守的單值文法。遇到無法辨識的動態結構時交由人工處理。"""

    def __init__(self, tokens):
        self.tokens = tokens
        self.position = 0
        self.format_spans = []

    def peek(self):
        if self.position < len(self.tokens):
            return self.tokens[self.position].text
        return ""

    def accept(self, value):
        if self.peek() == value:
            self.position += 1
            return True
        return False

    def require(self, value):
        if not self.accept(value):
            raise ComplexExpression("Lua expression 不完整")

    def take_name(self):
        if self.position < len(self.tokens):
            token = self.tokens[self.position]
            if token.kind == "identifier" and token.text not in KEYWORDS:
                self.position += 1
                return token.text
        raise ComplexExpression("需要 Lua 識別名稱")

    def parse(self):
        self.expression()
        if self.peek():
            raise ComplexExpression("需要單一 Lua expression")

    def expression(self, minimum=1, context=StringContext.TRANSLATABLE):
        if self.peek() in ("not", "-", "#", "~"):
            self.position += 1
            self.expression(11, context)
        else:
            self.atom(context)
        while (priority := PRECEDENCE.get(self.peek(), 0)) >= minimum:
            operator = self.peek()
            self.position += 1
            self.expression(priority + (operator not in ("^", "..")), context)

    def take_string(self, context):
        if context is not StringContext.TRANSLATABLE:
            raise ComplexExpression("字串位於索引或未知呼叫的參數位置")
        self.position += 1

    def atom(self, context):
        if self.position >= len(self.tokens):
            raise ComplexExpression("Lua expression 缺少值")
        token = self.tokens[self.position]
        if token.kind == "string":
            self.take_string(context)
            return
        if token.kind == "number":
            self.number()
            return
        if token.text in ("nil", "true", "false", "..."):
            self.position += 1
            return
        if self.accept("."):
            if self.position >= len(self.tokens) or token.end != self.tokens[self.position].start:
                raise ComplexExpression("Lua 小數格式無法辨識")
            self.number(prefix=".")
            return
        if self.accept("{"):
            self.table(context)
            return
        receiver_start = None
        if self.accept("("):
            receiver_start = self.position
            self.expression(context=context)
            self.require(")")
            name = "<expression>"
        else:
            name = self.take_name()
        self.suffix(name, context, receiver_start)

    def number(self, prefix=""):
        token = self.tokens[self.position]
        self.position += 1
        value = prefix + token.text
        exponent = "pP" if value.startswith(("0x", "0X")) else "eE"
        if value[-1] in exponent and self.position + 1 < len(self.tokens):
            sign, tail = self.tokens[self.position:self.position + 2]
            if (sign.text in ("+", "-") and token.end == sign.start and sign.end == tail.start
                    and DECIMAL_TAIL.fullmatch(tail.text)):
                value += sign.text + tail.text
                self.position += 2
        if not NUMBER.fullmatch(value):
            raise ComplexExpression("Lua 數字格式無法辨識")

    def suffix(self, name, context, receiver_start):
        while self.peek():
            if self.accept("."):
                name += "." + self.take_name()
            elif self.accept("["):
                self.expression(context=StringContext.INDEX)
                self.require("]")
                name = "<expression>"
            else:
                receiver_end = self.position - 1
                method = self.take_name() if self.accept(":") else None
                is_format = method is None and name in FORMAT_CALLS
                argument_context = context
                if not is_format and context is not StringContext.INDEX:
                    argument_context = StringContext.UNKNOWN_ARGUMENT
                if self.accept("("):
                    start = end = self.position
                    if not self.accept(")"):
                        self.expression(context=argument_context)
                        end = self.position
                        while self.accept(","):
                            self.expression(context=argument_context)
                        self.require(")")
                else:
                    start = self.position
                    if self.accept("{"):
                        self.table(argument_context)
                    elif self.position < len(self.tokens) and self.tokens[self.position].kind == "string":
                        self.take_string(argument_context)
                    elif method:
                        raise ComplexExpression("Lua 方法缺少參數")
                    else:
                        return
                    end = self.position
                if is_format:
                    self.format_spans.append((start, end))
                elif method == "format" and receiver_start is not None:
                    self.format_spans.append((receiver_start, receiver_end))
                name = "<expression>"
            receiver_start = None

    def table(self, context):
        while not self.accept("}"):
            if self.accept("["):
                self.expression(context=StringContext.INDEX)
                self.require("]")
                self.require("=")
            elif (self.position + 1 < len(self.tokens)
                  and self.tokens[self.position + 1].text == "="):
                self.take_name()
                self.require("=")
            self.expression(context=context)
            if not (self.accept(",") or self.accept(";")):
                self.require("}")
                return


def token_shape(tokens):
    return [(token.kind, None if token.kind == "string" else token.text) for token in tokens]


@dataclass(frozen=True)
class Template:
    raw: str
    tokens: list
    strings: list
    segments: dict
    format_groups: tuple[tuple[str, ...], ...]

    @classmethod
    def parse(cls, raw):
        try:
            tokens = tokenize(raw)
            parser = Expression(tokens)
            parser.parse()
            string_positions = [index for index, token in enumerate(tokens) if token.kind == "string"]
            strings = [tokens[index] for index in string_positions]
            if not strings:
                raise ComplexExpression("Lua expression 缺少可翻譯字串")
            segments = {f"s{index}": decode_string(token.text)
                        for index, token in enumerate(strings, 1)}
            keys_by_position = dict(zip(string_positions, segments))
            groups = tuple(
                tuple(keys_by_position[index] for index in range(start, end) if index in keys_by_position)
                for start, end in sorted(parser.format_spans)
            )
            return cls(raw, tokens, strings, segments, groups)
        except (UnicodeError, RecursionError, OverflowError, ValueError) as error:
            raise ComplexExpression("無法安全建立 Lua 模板") from error

    def render(self, segments):
        if segments.keys() != self.segments.keys():
            raise ValueError("segment_mismatch")
        fragments = []
        cursor = 0
        for key, token in zip(self.segments, self.strings):
            fragments.append(self.raw[cursor:token.start])
            fragments.append(quote(segments[key]))
            cursor = token.end
        fragments.append(self.raw[cursor:])
        expression = "".join(fragments)
        try:
            rendered = Template.parse(expression)
        except ComplexExpression:
            raise ValueError("lua_token_mismatch") from None
        if (token_shape(rendered.tokens) != token_shape(self.tokens)
                or rendered.segments != segments or rendered.format_groups != self.format_groups):
            raise ValueError("lua_token_mismatch")
        return expression
