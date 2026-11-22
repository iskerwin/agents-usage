"""Command line entry point."""

from __future__ import annotations

import argparse
import fcntl
import json
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from agents_usage import __version__
from agents_usage.logs import Scanner, rollup
from agents_usage.quota import (QuotaService, account_from_dict, age_account, cache_dir, capture_claude_statusline,
                                summarize, timezone_name, write_private)
from agents_usage.tasks import list_tasks

class Panel:
    def __init__(self, claude_live: bool) -> None:
        self.scanner = Scanner()
        self.quota = QuotaService(self.scanner, claude_live)

    def _build(self, quota: dict[str, Any], refreshing: bool = False) -> dict[str, Any]:
        usage = rollup(self.scanner.records())
        return {
            "version": __version__,
            "generated_at": int(time.time()),
            "timezone": timezone_name(),
            **quota,
            "usage": usage,
            "tasks": list_tasks(self.scanner),
            "refreshing": refreshing,
        }

    def snapshot(self, force: bool = False) -> dict[str, Any]:
        return self._build(self.quota.get(force))

    def current(self, refreshing: bool) -> Optional[dict[str, Any]]:
        """A snapshot that does not wait for quotas. None until some are known."""
        quota = self.quota.current()
        return None if quota is None else self._build(quota, refreshing)

    def save(self, snapshot: dict[str, Any]) -> None:
        write_private(saved_snapshot_path(), json.dumps(snapshot))

    def _saved(self) -> Optional[dict[str, Any]]:
        """The last saved snapshot, its quotas under the freshness rules again."""
        now = int(time.time())
        try:
            saved = json.loads(saved_snapshot_path().read_text())
            accounts = [age_account(account_from_dict(a), now) for a in saved["accounts"]]
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return None
        return {**saved, **summarize(accounts), "generated_at": now, "captured_at": saved.get("generated_at", 0)}

    def restored(self) -> Optional[dict[str, Any]]:
        """The last run's snapshot, to show while this run catches up, under the
        same freshness rules. Tasks are left out: their processes may be gone."""
        saved = self._saved()
        if saved is None:
            return None
        saved.pop("captured_at")
        return {**saved, "tasks": [], "refreshing": True}

    def shared(self) -> dict[str, Any]:
        """A snapshot whose quotas every process shares: the saved one while it
        is younger than the quota TTL, else a fresh one, saved for the others.
        Claude's live quota allows one call a minute, and each pane is a process
        of its own. The lock makes the others wait for that one call rather than
        make their own. Logs and tasks are this process's own and always current."""
        with _locked(cache_dir() / "snapshot.lock"):
            saved = self._saved()
            if saved is not None and saved["generated_at"] - saved["captured_at"] < self.quota.ttl:
                quota = {k: saved[k] for k in ("accounts", "most_urgent", "unmeasured")}
                return self._build(quota)
            snapshot = self.snapshot()
            self.save(snapshot)
            return snapshot


@contextmanager
def _locked(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def saved_snapshot_path() -> Path:
    return cache_dir() / "snapshot.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agents-usage", description="AI coding agent 的额度、用量和任务，给 macOS 菜单栏 app 用")
    parser.add_argument("command", nargs="?", choices=["capture-claude", "serve"],
                        help="capture-claude：从 stdin 读取 statusLine JSON 并保存配额快照；"
                             "serve：常驻进程，stdin 每收到一行就输出 JSON 快照（line 为 force 时强制刷新配额；"
                             "refreshing 为 true 表示配额刷新完后还会再输出一行）")
    parser.add_argument("--json", action="store_true", help="输出一次 JSON 快照后退出（一分钟内多个进程共用一次配额查询）")
    parser.add_argument("--claude-live", action="store_true",
                        help="读取 Claude Code 的 OAuth token（macOS 上可能弹出钥匙串授权）以查询实时配额")
    parser.add_argument("--version", action="version", version=__version__)
    return parser


def serve(panel: Panel) -> int:
    """JSON lines until stdin closes. Staying alive keeps the log cache and the
    Claude rate limit, which only exist in memory.

    A request is answered at once from what is known, because quotas take
    seconds. They refresh on a thread, and ``refreshing`` in a line says another
    line follows when that is done. The first request of a run has only the last
    run's snapshot to answer with, if any. The lock keeps a line saying
    ``refreshing`` from being printed after the one that ends the refresh."""
    lock = threading.Lock()
    refreshing = False
    restored_sent = False

    def send(build: Callable[[], Optional[dict[str, Any]]]) -> Optional[dict[str, Any]]:
        try:
            payload = build()
        except Exception as exc:
            payload = {"error": str(exc) or type(exc).__name__}
        if payload is not None:
            try:
                print(json.dumps(payload), flush=True)
            except (BrokenPipeError, ValueError):  # the reader is gone; stdin closing ends the loop
                pass
        return payload

    def refresh(force: bool) -> None:
        nonlocal refreshing
        # Parsing the logs alongside, so the first answer waits for neither in turn.
        threading.Thread(target=panel.scanner.records, daemon=True).start()
        failure: Optional[Exception] = None
        try:
            panel.quota.get(force)
        except Exception as exc:
            failure = exc
        with lock:
            refreshing = False
            if failure is not None:
                send(lambda: {"error": str(failure) or type(failure).__name__})
                return
            payload = send(lambda: panel.current(False))
        if payload is not None and "error" not in payload:
            try:
                panel.save(payload)
            except OSError:  # only a head start for the next run
                pass

    for line in sys.stdin:
        force = line.strip() == "force"
        with lock:
            if (force or panel.quota.due()) and not refreshing:
                refreshing = True
                threading.Thread(target=refresh, args=(force,), daemon=True).start()
            payload = send(lambda: panel.current(refreshing))
            if payload is None and not restored_sent:
                restored_sent = True
                send(panel.restored)
    return 0


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "capture-claude":
        # Runs inside the user's status line, so it must never break it.
        try:
            capture_claude_statusline(sys.stdin.read())
        except Exception:
            pass
        return 0
    if args.command == "serve":
        return serve(Panel(args.claude_live))

    if not args.json:
        build_parser().print_usage(sys.stderr)
        return 2
    # Many readers ask at once (an app, a pane in every tab): they share one
    # quota query a minute.
    print(json.dumps(Panel(args.claude_live).shared(), ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
