"""Command line entry point."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

from agents_usage import __version__
from agents_usage.logs import Scanner, rollup
from agents_usage.quota import (QuotaService, account_from_dict, age_account, cache_dir, capture_claude_statusline,
                                summarize, timezone_name, write_private)
from agents_usage.render import MAX_WIDTH, METRICS, ViewOptions, build_view, to_ansi
from agents_usage.tasks import list_tasks
from agents_usage.tui import terminal_size, watch

MIN_WATCH_SECONDS = 5


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

    def restored(self) -> Optional[dict[str, Any]]:
        """The last run's snapshot, to show while this run catches up, under the
        same freshness rules. Tasks are left out: their processes may be gone."""
        now = int(time.time())
        try:
            saved = json.loads(saved_snapshot_path().read_text())
            accounts = [age_account(account_from_dict(a), now) for a in saved["accounts"]]
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return None
        return {**saved, **summarize(accounts), "generated_at": now, "tasks": [], "refreshing": True}


def saved_snapshot_path() -> Path:
    return cache_dir() / "snapshot.json"


def wants_color(no_color: bool) -> bool:
    return not (no_color or "NO_COLOR" in os.environ or os.environ.get("TERM") == "dumb" or not sys.stdout.isatty())


def supports_unicode() -> bool:
    return (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "").startswith("utf")


def positive_int(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("必须是正整数")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agents-usage", description="AI coding agent 用量面板")
    parser.add_argument("command", nargs="?", choices=["capture-claude", "serve"],
                        help="capture-claude：从 stdin 读取 statusLine JSON 并保存配额快照；"
                             "serve：常驻进程，stdin 每收到一行就输出 JSON 快照（line 为 force 时强制刷新配额；"
                             "refreshing 为 true 表示配额刷新完后还会再输出一行）")
    parser.add_argument("--watch", type=positive_int, nargs="?", const=60, metavar="秒",
                        help="全屏持续刷新（默认每 60 秒），按 q 退出")
    parser.add_argument("--days", type=positive_int, default=7, help="统计最近几天（默认 7）")
    parser.add_argument("--agent", choices=["all", "claude", "codex", "grok"], default="all")
    parser.add_argument("--metric", choices=list(METRICS), default="billable",
                        help="billable：不含缓存读取（默认）；total：全部 Token；output：仅输出")
    parser.add_argument("--projects", action="store_true", help="同时显示项目明细")
    parser.add_argument("--json", action="store_true", help="输出 JSON 后退出")
    parser.add_argument("--no-color", action="store_true", help="不使用颜色")
    # There are no animations left. Still accepted, so existing scripts keep working.
    parser.add_argument("--no-anim", action="store_true", help=argparse.SUPPRESS)
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

    # A locale that cannot encode the labels must not crash the view.
    sys.stdout.reconfigure(errors="replace")  # type: ignore[union-attr]
    panel = Panel(args.claude_live)
    if args.json:
        print(json.dumps(panel.snapshot(), ensure_ascii=False, indent=2))
        return 0

    color = wants_color(args.no_color)
    width, _ = terminal_size()
    opts = ViewOptions(width=min(width, MAX_WIDTH), days=args.days, agent=args.agent, metric=args.metric,
                       projects=args.projects, unicode=supports_unicode())
    if args.watch is not None:
        if not sys.stdout.isatty():
            print("--watch 需要在交互式终端中运行", file=sys.stderr)
            return 2
        watch(panel.snapshot, opts, color, max(args.watch, MIN_WATCH_SECONDS))
        return 0
    # Reading the quotas can take seconds, and a silent terminal looks stuck.
    waiting = sys.stderr.isatty() and sys.stdout.isatty()
    if waiting:
        print("读取中\r", end="", file=sys.stderr, flush=True)
    snapshot = panel.snapshot()
    if waiting:
        print("\x1b[K", end="", file=sys.stderr, flush=True)
    for line in build_view(snapshot, opts):
        print(to_ansi(line, color))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
