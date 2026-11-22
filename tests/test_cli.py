import io
import json
import os
import subprocess
import sys
import threading

from agents_usage.cli import serve


class FakeQuota:
    def __init__(self, known: bool = True, failing: bool = False) -> None:
        self.known = known
        self.failing = failing
        self.forced: list[bool] = []
        self.overdue = True

    def due(self) -> bool:
        return self.overdue

    def get(self, force: bool = False) -> None:
        self.forced.append(force)
        if self.failing:
            raise RuntimeError("boom")
        self.known = True
        self.overdue = False


class FakeScanner:
    def records(self) -> list:
        return []


class FakePanel:
    def __init__(self, quota: FakeQuota, saved: dict | None = None) -> None:
        self.quota = quota
        self.scanner = FakeScanner()
        self.saved = saved
        self.stored: list[dict] = []

    def current(self, refreshing: bool) -> dict | None:
        return {"refreshing": refreshing} if self.quota.known else None

    def restored(self) -> dict | None:
        return self.saved

    def save(self, snapshot: dict) -> None:
        self.stored.append(snapshot)


def run_serve(panel, monkeypatch, capsys, text: str) -> list[dict]:
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))
    assert serve(panel) == 0
    for thread in threading.enumerate():
        if thread is not threading.main_thread():
            thread.join(5)
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_serve_answers_at_once_from_what_it_knows_and_again_after_refreshing(monkeypatch, capsys):
    panel = FakePanel(FakeQuota())
    lines = run_serve(panel, monkeypatch, capsys, "get\n")
    assert lines[-1] == {"refreshing": False}
    assert {"refreshing": True} in lines
    assert panel.stored == [{"refreshing": False}]


def test_serve_does_not_refresh_quotas_that_are_not_due(monkeypatch, capsys):
    quota = FakeQuota()
    quota.overdue = False
    assert run_serve(FakePanel(quota), monkeypatch, capsys, "get\n") == [{"refreshing": False}]
    assert quota.forced == []


def test_serve_only_forces_when_asked(monkeypatch, capsys):
    quota = FakeQuota()
    quota.overdue = False
    run_serve(FakePanel(quota), monkeypatch, capsys, "force\n")
    assert quota.forced == [True]


def test_serve_starts_from_the_last_run_when_it_knows_nothing_yet(monkeypatch, capsys):
    panel = FakePanel(FakeQuota(known=False), saved={"restored": True})
    assert run_serve(panel, monkeypatch, capsys, "get\n") == [{"restored": True}, {"refreshing": False}]


def test_serve_reports_a_failed_refresh(monkeypatch, capsys):
    panel = FakePanel(FakeQuota(known=False, failing=True))
    assert run_serve(panel, monkeypatch, capsys, "get\n") == [{"error": "boom"}]
    assert panel.stored == []


def run_cli(tmp_path, *args):
    env = {**os.environ, "HOME": str(tmp_path), "CODEX_HOME": str(tmp_path / "codex"), "CLAUDE_CONFIG_DIR": str(tmp_path / "claude")}
    return subprocess.run([sys.executable, "-m", "agents_usage.cli", *args], capture_output=True, text=True, env=env, timeout=60)


def test_json_parses_and_bare_runs_ask_for_it(tmp_path):
    assert json.loads(run_cli(tmp_path, "--json").stdout)["version"]
    assert run_cli(tmp_path).returncode == 2
