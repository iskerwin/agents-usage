import io
import json
import sys

from agents_usage.cli import serve


class FakePanel:
    def __init__(self, failing: bool = False) -> None:
        self.failing = failing
        self.calls: list[bool] = []

    def snapshot(self, force: bool = False) -> dict:
        self.calls.append(force)
        if self.failing:
            raise RuntimeError("boom")
        return {"call": len(self.calls)}


def run_serve(panel, monkeypatch, capsys, text: str) -> list[dict]:
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))
    assert serve(panel) == 0
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_serve_answers_each_line_and_only_forces_when_asked(monkeypatch, capsys):
    panel = FakePanel()
    assert run_serve(panel, monkeypatch, capsys, "get\nforce\n") == [{"call": 1}, {"call": 2}]
    assert panel.calls == [False, True]


def test_serve_survives_a_failed_snapshot(monkeypatch, capsys):
    assert run_serve(FakePanel(failing=True), monkeypatch, capsys, "get\n") == [{"error": "boom"}]
