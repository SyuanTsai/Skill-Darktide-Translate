import os
from pathlib import Path

import pytest

from checks import Luac, validate
from glossary import Glossary
from lua_template import ComplexExpression, Template, decode_string, tokenize


@pytest.mark.parametrize("value", ['"', "\\", "]]", '" .. os.execute("x") .. "', "\r", "\0"])
def test_4_5_lua_special_inputs(value):
    template = Template.parse('"one" .. identifier')
    if value in ("\r", "\0"):
        with pytest.raises(ValueError):
            template.render({"s1": value})
    else:
        tokens = tokenize(template.render({"s1": value}))
        assert decode_string(tokens[0].text) == value
        assert [token.text for token in tokens[1:]] == ["..", "identifier"]


@pytest.mark.parametrize("expression", [
    'some_variable', 'Localize("key") .. "sentence"', '"a" .. lookup("key")',
    '"a" .. helper(1, "key")', '"unclosed', '"a" @ "b"', '"a"; doSomething()',
    '"a" ..', '"a" "b"', 'lookup "key" .. "sentence"',
])
def test_4_5_complex_expressions(expression):
    with pytest.raises(ComplexExpression):
        Template.parse(expression)


def test_4_5_long_strings_and_format():
    template = Template.parse("string.format([=[Hello %s]=], user) .. [[!]] .. 'ok'")
    assert template.segments == {"s1": "Hello %s", "s2": "!", "s3": "ok"}
    assert template.render({"s1": "你好 %s", "s2": "！", "s3": "好"}) == (
        'string.format("你好 %s", user) .. "！" .. "好"')


def test_4_5_scanner_number_tokens_and_original_trivia():
    raw = '"Speed" -- comment\r\n .. string.format("%s", 1e-3)'
    template = Template.parse(raw)
    assert [token.text for token in tokenize(raw)][-4:] == ["1e", "-", "3", ")"]
    assert template.render({"s1": "速度", "s2": "%s"}) == (
        '"速度" -- comment\r\n .. string.format("%s", 1e-3)')


@pytest.fixture
def terms():
    return Glossary.parse((Path(__file__).parent / "fixtures/terms.md").read_text(encoding="utf-8"))


def test_ac3_exact_glossary_and_scoped_checks(terms):
    assert "glossary_term_missing" in validate(Template.parse('"Weakspot"'), {"s1": "弱處"}, terms, Luac(None))[1]
    assert validate(Template.parse('"Finesse"'), {"s1": "靈巧傷害"}, terms, Luac(None))[1] == []


def assert_reference_terms(glossary):
    for text, count in {"Finesse": 2, "Flamer": 2, "Damage vs Maniacs": 3,
                        "Damage vs Groaners and Poxwalkers": 3, "Run 'n' Gun": 1,
                        "Run and Gun": 1, "Perils of the Warp": 2}.items():
        entries = glossary.match(text)
        assert len(entries) == count, (text, entries)
    assert all(entry.translation != "反噬" for entry in glossary.match("Perils of the Warp"))
    assert {entry.translation for entry in glossary.match("PERILS")} == {"反噬"}


def test_4_6_glossary_cases(terms):
    assert_reference_terms(terms)
    assert len(terms.match("Companion")) == 2
    assert not terms.match("superfinesse")


def test_4_6_live_glossary_smoke():
    root = os.environ.get("DARKTIDE_MODS_ROOT")
    if not root:
        pytest.skip("需設定 DARKTIDE_MODS_ROOT")
    glossary = Glossary.parse((Path(root) / "Referneces/Translation.md").read_text(encoding="utf-8-sig"))
    assert len(glossary.entries) > 1000
    assert_reference_terms(glossary)


@pytest.mark.parametrize(("changed", "reason"), [
    ("{name}", "placeholder_mismatch"), ("{name:%s}", "placeholder_mismatch"),
    ("{name:%d}", "placeholder_mismatch"), ("%s", "placeholder_mismatch"),
    ("%d", "placeholder_mismatch"), ("%i", "placeholder_mismatch"),
    ("%.1f", "placeholder_mismatch"), ("%%", "placeholder_mismatch"),
    ("{#color(255,0,0)}", "markup_mismatch"), ("{#reset()}", "markup_mismatch"),
    ("\n", "newline_mismatch"), ("-2.5%", "number_mismatch"),
])
def test_ac4_structure(changed, reason, terms):
    text = "{name} {name:%s} {name:%d} %s %d %i %.1f %% {#color(255,0,0)}x{#reset()}\n -2.5% {damage:%s}{damage:%s}"
    template = Template.parse('"' + text.replace("\n", "\\n") + '"')
    assert validate(template, {"s1": text}, terms, Luac(None))[1] == []
    assert reason in validate(template, {"s1": text.replace(changed, "", 1)}, terms, Luac(None))[1]


def test_unpaired_source_markup_preserves_token_sequence(terms):
    template = Template.parse('"{#color(255,0,0)}English"')
    assert validate(template, {"s1": "{#color(255,0,0)}譯文"}, terms, Luac(None))[1] == []


def test_4_4_format_order_controls_and_numbers(terms):
    assert "format_order_mismatch" in validate(Template.parse('string.format("%s %d", a,b)'),
                                              {"s1": "%d %s"}, terms, Luac(None))[1]
    assert "invalid_control_character" in validate(Template.parse('"A"'),
                                                    {"s1": "甲\x85"}, terms, Luac(None))[1]
    assert validate(Template.parse('"x2"'), {"s1": "2 倍"}, terms, Luac(None))[1] == []


@pytest.mark.parametrize("available", [True, False])
def test_4_5_optional_luac(available, terms):
    calls = []
    def runner(argv, **kwargs):
        assert argv[1] == "-p"
        calls.append(Path(argv[2]).read_text(encoding="utf-8"))
        return type("Result", (), {"returncode": 1})()

    luac = Luac("luac" if available else None, runner)
    _, issues = validate(Template.parse('"one"'), {"s1": "一"}, terms, luac)
    assert luac.available == available
    assert calls == (['return { x = "一" }\n'] if available else [])
    assert ("luac_syntax_error" in issues) == available
