"""agents-meter writes account notes in Chinese; the menu bar app translates
them by replacing known fragments (``localizedNote`` in Localization.swift).
A new or reworded fragment in agents-meter would otherwise show up half in
Chinese, so every Chinese literal in agents-meter's quota module must come out
of that table with no Chinese left. It runs against the locked agents-meter,
so it fails when a lock upgrade brings text the table does not cover yet."""

import ast
import re
from pathlib import Path

import agents_meter.quota

LOCALIZATION = Path(__file__).parents[1] / "macos/Sources/AgentsUsageKit/Localization.swift"
CJK = re.compile(r"[　-〿一-鿿＀-￯]")
# Window labels: the app builds its own from `seconds` and `model`.
NOT_NOTES = {"window_label"}


def note_fragments() -> set[str]:
    tree = ast.parse(Path(agents_meter.quota.__file__).read_text())
    skipped: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.Module)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                skipped.add(id(body[0].value))  # docstring
            if getattr(node, "name", None) in NOT_NOTES:
                skipped.update(id(n) for n in ast.walk(node))
    return {
        n.value for n in ast.walk(tree)
        if isinstance(n, ast.Constant) and isinstance(n.value, str)
        and id(n) not in skipped and CJK.search(n.value)
    }


def swift_table() -> list[tuple[str, str]]:
    source = LOCALIZATION.read_text()
    body = source[source.index("func localizedNote"):]
    body = body[:body.index("return known.reduce")]
    literal = r'"((?:[^"\\]|\\.)*)"'
    return re.findall(rf"\(\s*{literal},\s*{literal}\s*\)", body)


def translate(note: str, table: list[tuple[str, str]]) -> str:
    for chinese, english in table:
        note = note.replace(chinese, english)
    return note


def test_scan_finds_the_notes() -> None:
    fragments = note_fragments()
    assert agents_meter.quota.CLAUDE_SETUP_NOTE in fragments
    assert "每周" not in fragments


def test_every_note_fragment_is_translated() -> None:
    table = swift_table()
    left = {f: translate(f, table) for f in note_fragments() if CJK.search(translate(f, table))}
    assert not left, f"add these to localizedNote in {LOCALIZATION.name}: {left}"
