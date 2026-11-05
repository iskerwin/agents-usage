"""Command line entry point."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Callable, Optional

from agents_usage import __version__
from agents_usage.logs import Scanner, rollup
from agents_usage.quota import QuotaService, capture_claude_statusline, timezone_name
from agents_usage.render import METRICS, Caps, ViewOptions, build_view
from agents_usage.tui import fetch_with_boot, print_view, terminal_size, watch

MIN_WATCH_SECONDS = 5
MAX_ONE_SHOT_WIDTH = 110

Step = Callable[[str, Optional[str]], None]


class Panel:
    def __init__(self, claude_live: bool) -> None:
        self.scanner = Scanner()
        self.quota = QuotaService(self.scanner, claude_live)

    def snapshot(self, force: bool = False, on_step: Optional[Step] = None) -> dict[str, Any]:
        step = on_step or (lambda label, detail: None)
        step("解析会话日志", None)
        records = self.scanner.records()
        usage = rollup(records)
        step("解析会话日志", f"{self.scanner.file_count} 个文件 · {len(records):,} 条记录")
        step("读取配额", None)
        quota = self.quota.get(force)
        windows = sum(len(a["windows"]) for a in quota["accounts"])
        step("读取配额", f"{len(quota['accounts'])} 个 agent · {windows} 个窗口")
        return {
            "version": __version__,
            "generated_at": int(time.time()),
            "timezone": timezone_name(),
            **quota,
            "usage": usage,
        }


def detect_caps(no_color: bool) -> Caps:
    encoding = (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "")
    unicode = encoding.startswith("utf")
    term = os.environ.get("TERM", "")
    if no_color or "NO_COLOR" in os.environ or term == "dumb" or not sys.stdout.isatty():
        return Caps(color=0, unicode=unicode)
    truecolor = os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit")
    return Caps(color=24 if truecolor else 256, unicode=unicode)


def positive_int(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("必须是正整数")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agents-usage", description="AI coding agent 用量面板")
    parser.add_argument("command", nargs="?", choices=["capture-claude", "serve"],
                        help="capture-claude：从 stdin 读取 statusLine JSON 并保存配额快照；"
                             "serve：常驻进程，stdin 每收到一行就输出一行 JSON 快照（line 为 force 时强制刷新配额）")
    parser.add_argument("--watch", type=positive_int, nargs="?", const=60, metavar="秒",
                        help="全屏持续刷新（默认每 60 秒），按 q 退出")
    parser.add_argument("--days", type=positive_int, default=7, help="统计最近几天（默认 7）")
    parser.add_argument("--agent", choices=["all", "claude", "codex", "grok"], default="all")
    parser.add_argument("--metric", choices=list(METRICS), default="billable",
                        help="billable：不含缓存读取（默认）；total：全部 Token；output：仅输出")
    parser.add_argument("--projects", action="store_true", help="同时显示项目明细")
    parser.add_argument("--json", action="store_true", help="输出 JSON 后退出")
    parser.add_argument("--no-color", action="store_true", help="不使用颜色")
    parser.add_argument("--no-anim", action="store_true", help="不播放动画")
    parser.add_argument("--claude-live", action="store_true",
                        help="读取 Claude Code 的 OAuth token（macOS 上可能弹出钥匙串授权）以查询实时配额")
    parser.add_argument("--version", action="version", version=__version__)
    return parser


def serve(panel: Panel) -> int:
    """One JSON line per request, until stdin closes. Staying alive keeps the
    log cache and the Claude rate limit, which only exist in memory."""
    for line in sys.stdin:
        try:
            payload = panel.snapshot(force=line.strip() == "force")
        except Exception as exc:
            payload = {"error": str(exc) or type(exc).__name__}
        try:
            print(json.dumps(payload), flush=True)
        except BrokenPipeError:
            break
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

    caps = detect_caps(args.no_color)
    width, _ = terminal_size()
    opts = ViewOptions(width=min(width, MAX_ONE_SHOT_WIDTH), days=args.days, agent=args.agent, metric=args.metric,
                       projects=args.projects, unicode=caps.unicode)
    interactive = sys.stdout.isatty() and bool(caps.color)
    if args.watch is not None:
        if not sys.stdout.isatty():
            print("--watch 需要在交互式终端中运行", file=sys.stderr)
            return 2
        watch(panel.snapshot, opts, caps, max(args.watch, MIN_WATCH_SECONDS))
        return 0
    animate = interactive and not args.no_anim
    snapshot = fetch_with_boot(panel.snapshot, caps) if animate else panel.snapshot()
    print_view(build_view(snapshot, opts), caps, animate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
