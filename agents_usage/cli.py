"""Command line entry point."""

from __future__ import annotations

import argparse
import json
import sys
import threading
from typing import Any, Callable, Optional

from agents_meter.quota import capture_claude_statusline
from agents_meter.snapshot import Snapshots

from agents_usage import __version__


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agents-usage", description="AI coding agent 的额度、用量和任务，给 macOS 菜单栏 app 用")
    parser.add_argument("command", nargs="?", choices=["capture-claude", "serve"],
                        help="capture-claude：从 stdin 读取 statusLine JSON 并保存配额快照；"
                             "serve：常驻进程，stdin 每收到一行就输出 JSON 快照（line 为 force 时强制刷新配额；"
                             "refreshing 为 true 表示配额刷新完后还会再输出一行）")
    parser.add_argument("--json", action="store_true", help="输出一次 JSON 快照后退出")
    parser.add_argument("--claude-live", action="store_true",
                        help="读取 Claude Code 的 OAuth token（macOS 上可能弹出钥匙串授权）以查询实时配额")
    parser.add_argument("--version", action="version", version=__version__)
    return parser


def serve(panel: Snapshots) -> int:
    """JSON lines until stdin closes. Staying alive keeps the log cache, which
    only exists in memory.

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
        return serve(Snapshots(args.claude_live))

    if not args.json:
        build_parser().print_usage(sys.stderr)
        return 2
    print(json.dumps(Snapshots(args.claude_live)(), ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
