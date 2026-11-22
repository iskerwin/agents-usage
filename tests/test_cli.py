import io
import json
import os
import stat
import subprocess
import sys
import threading
import time

from agents_usage.cli import Panel, saved_snapshot_path, serve
from agents_usage.quota import Account, Window


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


def saved_snapshot(captured_at: int, resets_at: int) -> dict:
    account = Account("codex", "Codex", captured_at=captured_at, windows=[Window("5 小时", 10, resets_at)])
    return {"accounts": [account.to_dict()], "usage": {"rows": []}, "tasks": [{"pid": 1}], "generated_at": 1}


def test_restored_snapshot_is_held_to_the_freshness_rules(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    panel = Panel(False)
    panel.save(saved_snapshot(captured_at=1000, resets_at=2**40))
    assert stat.S_IMODE(os.stat(saved_snapshot_path()).st_mode) == 0o600

    restored = panel.restored()
    assert restored["accounts"][0]["stale"] is True
    assert restored["most_urgent"] is None
    assert restored["tasks"] == []
    assert restored["refreshing"] is True
    assert restored["generated_at"] > 1

    panel.save(saved_snapshot(captured_at=1000, resets_at=2000))
    assert panel.restored()["accounts"][0]["windows"] == []


def test_a_missing_or_foreign_saved_snapshot_is_ignored(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    panel = Panel(False)
    assert panel.restored() is None
    saved_snapshot_path().parent.mkdir(parents=True)
    for text in ("{not json", "[]", '{"accounts": [{"name": "x"}]}'):
        saved_snapshot_path().write_text(text)
        assert panel.restored() is None


class CountingQuota:
    ttl = 60

    def __init__(self):
        self.calls = 0

    def get(self, force=False):
        self.calls += 1
        time.sleep(0.05)
        return {"accounts": [], "most_urgent": None, "unmeasured": []}


class NoLogs:
    def records(self):
        return []


def panel(quota):
    p = Panel.__new__(Panel)
    p.scanner, p.quota = NoLogs(), quota
    return p


def test_panes_share_one_quota_query(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    monkeypatch.setattr("agents_usage.cli.list_tasks", lambda scanner: [])
    quotas = [CountingQuota() for _ in range(4)]
    threads = [threading.Thread(target=panel(q).shared) for q in quotas]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sum(q.calls for q in quotas) == 1
    assert json.loads(saved_snapshot_path().read_text())["accounts"] == []


def test_an_old_shared_snapshot_is_queried_again(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    monkeypatch.setattr("agents_usage.cli.list_tasks", lambda scanner: [])
    first = CountingQuota()
    panel(first).shared()
    saved = json.loads(saved_snapshot_path().read_text())
    saved_snapshot_path().write_text(json.dumps({**saved, "generated_at": int(time.time()) - 61}))
    again = CountingQuota()
    panel(again).shared()
    assert again.calls == 1


def run_cli(tmp_path, *args):
    env = {**os.environ, "HOME": str(tmp_path), "CODEX_HOME": str(tmp_path / "codex"), "CLAUDE_CONFIG_DIR": str(tmp_path / "claude")}
    return subprocess.run([sys.executable, "-m", "agents_usage.cli", *args], capture_output=True, text=True, env=env, timeout=60)


def test_json_parses_and_bare_runs_ask_for_it(tmp_path):
    assert json.loads(run_cli(tmp_path, "--json").stdout)["version"]
    assert run_cli(tmp_path).returncode == 2
