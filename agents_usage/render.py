"""Builds the terminal view from a snapshot. Pure: no I/O and no clock.

A view is a list of lines, a line a list of spans, so widths can be measured
and cut without having to parse escape codes.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, NamedTuple, Optional

# SGR codes. The terminal's own palette, so it reads on any background.
MUTED = "2"
LOW = "33"
CRITICAL = "31"

MAX_WIDTH = 72
LEVEL_COLOR = {"low": LOW, "critical": CRITICAL}
# Never by color alone.
LEVEL_MARK = {"low": "▲", "critical": "■"}
LEVEL_MARK_ASCII = {"low": "!", "critical": "!!"}

METRICS: dict[str, tuple[str, Callable[[dict[str, Any]], int]]] = {
    "billable": ("不含缓存读取", lambda r: r["fresh"] + r["cache_write"] + r["output"]),
    "total": ("全部 Token", lambda r: r["fresh"] + r["cache_read"] + r["cache_write"] + r["output"]),
    "output": ("仅输出", lambda r: r["output"]),
}


class Span(NamedTuple):
    text: str
    color: Optional[str] = None
    bold: bool = False


Line = list[Span]


@dataclass(frozen=True)
class ViewOptions:
    width: int = MAX_WIDTH
    days: int = 7
    agent: str = "all"
    metric: str = "billable"
    projects: bool = False
    unicode: bool = True


# ------------------------------------------------------------------ text
def char_width(ch: str) -> int:
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text: str) -> int:
    return sum(char_width(c) for c in text)


def line_width(line: Line) -> int:
    return sum(text_width(s.text) for s in line)


def plain(line: Line) -> str:
    return "".join(s.text for s in line)


def fit(line: Line, width: int) -> Line:
    """Exactly `width` cells: padded, or cut with an ellipsis."""
    current = line_width(line)
    if current <= width:
        return [*line, Span(" " * (width - current))] if current < width else list(line)
    out: Line = []
    room = max(width - 1, 0)
    for span in line:
        kept = ""
        for ch in span.text:
            w = char_width(ch)
            if w > room:
                room = -1
                break
            kept += ch
            room -= w
        if kept:
            out.append(Span(kept, span.color, span.bold))
        if room < 0:
            break
    out.append(Span("…", MUTED))
    return [*out, Span(" " * (width - line_width(out)))]


def wrap_text(text: str, width: int) -> list[str]:
    lines = [""]
    for ch in text:
        if text_width(lines[-1]) + char_width(ch) > width:
            lines.append("")
        lines[-1] += ch
    return lines


def pad_text(text: str, width: int, right: bool = False) -> str:
    gap = " " * max(width - text_width(text), 0)
    return gap + text if right else text + gap


def to_ansi(line: Line, color: bool) -> str:
    if not color:
        return plain(line)
    out: list[str] = []
    for span in line:
        codes = [code for code in ("1" if span.bold else None, span.color) if code]
        # Blanks show no color, so a run of them needs no escape codes.
        if codes and span.text.strip():
            out.append(f"\x1b[{';'.join(codes)}m{span.text}\x1b[0m")
        else:
            out.append(span.text)
    return "".join(out)


# ------------------------------------------------------------------ values
def compact(n: float) -> str:
    for size, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if n >= size:
            v = n / size
            return f"{round(v, 0 if v >= 100 else 1 if v >= 10 else 2):g}{unit}"
    return str(round(n))


def duration(seconds: float) -> str:
    seconds = max(seconds, 0)
    if seconds < 60:
        return "不到 1 分钟"
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days} 天 {hours} 小时"
    return f"{hours} 小时 {minutes} 分钟" if hours else f"{minutes} 分钟"


def plan_text(plan: str) -> str:
    return plan.capitalize() if plan.islower() else plan


def short_path(path: str) -> str:
    parts = path.split("/")
    return f"…/{'/'.join(parts[-2:])}" if len(parts) > 3 else path


# ------------------------------------------------------------------ pieces
def bar(fraction: float, width: int, color: Optional[str], unicode: bool) -> Line:
    full = round(fraction * width)
    # Rounding must not make a nearly empty bar look empty, or a nearly full
    # one look full.
    if fraction > 0:
        full = max(full, 1)
    if fraction < 1:
        full = min(full, width - 1)
    on, off = ("█", "░") if unicode else ("#", ".")
    return [Span(on * full, color), Span(off * (width - full), MUTED)]


def _window(window: dict[str, Any], width: int, now: int, unicode: bool) -> Line:
    level = window["level"]
    color = LEVEL_COLOR.get(level)
    marks = LEVEL_MARK if unicode else LEVEL_MARK_ASCII
    label = pad_text(window["label"], 14 if "(" in window["label"] else 8)
    percent = pad_text(f"{marks.get(level, '')} {round(window['left_percent'])}%".strip(), 7, True)
    reset_at = window.get("resets_at")
    reset = pad_text(duration(reset_at - now) if reset_at else "—", 16, True)
    bar_width = max(width - text_width(label) - 7 - 16, 8)
    return [Span(label), *bar(window["left_percent"] / 100, bar_width, color, unicode),
            Span(percent, color, True), Span(reset, MUTED)]


def _quota(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    now = snap["generated_at"]
    lines: list[Line] = []
    if not snap["accounts"]:
        lines.append([Span("没有检测到已安装的 agent", MUTED)])
    for account in snap["accounts"]:
        title: Line = [Span(account["name"], None, True)]
        if account.get("plan"):
            title.append(Span(f"  {plan_text(account['plan'])}", MUTED))
        if account.get("email"):
            title.append(Span(f"  {account['email']}", MUTED))
        if account.get("stale"):
            title.append(Span("  已过期", LOW, True))
        lines.append(title)
        lines.extend(_window(window, opts.width, now, opts.unicode) for window in account["windows"])
        if account.get("note"):
            lines.extend([Span(part, MUTED)] for part in wrap_text(account["note"], opts.width))
        lines.append([])
    return lines


def select_rows(snap: dict[str, Any], opts: ViewOptions) -> tuple[list[str], list[dict[str, Any]]]:
    today = datetime.fromtimestamp(snap["generated_at"]).date()
    days = [(today - timedelta(days=i)).isoformat() for i in range(opts.days - 1, -1, -1)]
    rows = [r for r in snap["usage"]["rows"]
            if r["date"] >= days[0] and (opts.agent == "all" or r["agent"] == opts.agent)]
    return days, rows


def _daily(days: list[str], rows: list[dict[str, Any]], opts: ViewOptions) -> list[Line]:
    value = METRICS[opts.metric][1]
    totals = {day: 0 for day in days}
    for r in rows:
        totals[r["date"]] = totals.get(r["date"], 0) + value(r)
    peak = max(totals.values(), default=0) or 1
    bar_width = max(opts.width - 6 - 8, 8)
    return [[Span(day[5:].replace("-", "/") + " ", MUTED),
             *bar(totals[day] / peak, bar_width, None, opts.unicode),
             Span(pad_text(compact(totals[day]) if totals[day] else "—", 8, True), MUTED)]
            for day in days]


def _ranking(rows: list[dict[str, Any]], key: Callable[[dict[str, Any]], str],
             opts: ViewOptions, limit: int = 6) -> list[Line]:
    value = METRICS[opts.metric][1]
    totals: dict[str, int] = {}
    for r in rows:
        totals[key(r)] = totals.get(key(r), 0) + value(r)
    ordered = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)
    shown = ordered[:limit]
    if ordered[limit:]:
        shown.append((f"其他 {len(ordered) - limit} 项", sum(amount for _, amount in ordered[limit:])))
    return [[*fit([Span(name)], opts.width - 8), Span(pad_text(compact(amount), 8, True), MUTED)]
            for name, amount in shown]


def _usage(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    days, rows = select_rows(snap, opts)
    label = f"最近 {opts.days} 天"
    if opts.metric != "billable":
        label += f" · {METRICS[opts.metric][0]}"
    if not rows:
        return [[Span(label, None, True), Span("  没有用量记录", MUTED)]]
    total = sum(METRICS[opts.metric][1](r) for r in rows)
    lines: list[Line] = [[Span(label, None, True), Span(f"  {compact(total)}", None, True)]]
    lines.extend(_daily(days, rows, opts))
    lines.append([])
    lines.extend(_ranking(rows, lambda r: r["model"], opts))
    if opts.projects:
        lines.append([])
        lines.extend(_ranking(rows, lambda r: short_path(r["project"]), opts, limit=8))
    return lines


def build_view(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    lines = [*_quota(snap, opts), *_usage(snap, opts)]
    # Nothing may wrap: watch mode addresses lines by row.
    return [fit(line, opts.width) if line_width(line) > opts.width else line for line in lines]
