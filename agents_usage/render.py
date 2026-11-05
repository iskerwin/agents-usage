"""Builds the terminal view from a snapshot. Pure: no I/O and no clock.

A view is a list of lines, a line a list of spans, so the animations in tui.py
can work on characters without having to parse escape codes.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Callable, NamedTuple, Optional

RGB = tuple[int, int, int]

# Dracula, https://draculatheme.com/contribute
BACKGROUND = (40, 42, 54)
INK = (248, 248, 242)
TRACK = (68, 71, 90)  # current line
BORDER = (98, 114, 164)  # comment
MUTED = (143, 154, 187)  # comment lightened: comment itself is too dim for text
ACCENT = (80, 250, 123)  # green
PURPLE = (189, 147, 249)
PINK = (255, 121, 198)
AMBER = (255, 184, 108)  # orange
RED = (255, 85, 85)
CLAUDE = (139, 233, 253)  # cyan
CODEX = PINK
GROK = PURPLE

AGENT_COLOR = {"claude": CLAUDE, "codex": CODEX, "grok": GROK}
AGENT_NAME = {"claude": "Claude Code", "codex": "Codex", "grok": "Grok"}
LEVEL_COLOR = {"ok": ACCENT, "low": AMBER, "critical": RED}
LEVEL_TEXT = {"low": "▲ 偏低", "critical": "■ 紧张"}
LEVEL_TEXT_ASCII = {"low": "! 偏低", "critical": "!! 紧张"}

METRICS: dict[str, tuple[str, Callable[[dict[str, Any]], int]]] = {
    "billable": ("不含缓存读取", lambda r: r["fresh"] + r["cache_write"] + r["output"]),
    "total": ("全部 Token", lambda r: r["fresh"] + r["cache_read"] + r["cache_write"] + r["output"]),
    "output": ("仅输出", lambda r: r["output"]),
}

BANNER = (
    " █████╗  ██████╗ ███████╗███╗   ██╗████████╗███████╗",
    "██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝██╔════╝",
    "███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   ███████╗",
    "██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   ╚════██║",
    "██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   ███████║",
    "╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝",
)
BANNER_WIDTH = 52
SIDE_PANEL_MIN_WIDTH = BANNER_WIDTH + 26


class Span(NamedTuple):
    text: str
    color: Optional[RGB] = None
    bold: bool = False


Line = list[Span]


@dataclass(frozen=True)
class Caps:
    color: int = 24  # 24 (truecolor), 256 or 0
    unicode: bool = True


@dataclass(frozen=True)
class ViewOptions:
    width: int = 100
    days: int = 7
    agent: str = "all"
    metric: str = "billable"
    projects: bool = False
    compact: bool = False
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


def _sgr(color: RGB, bold: bool, depth: int) -> str:
    codes = ["1"] if bold else []
    if depth == 24:
        codes.append("38;2;{};{};{}".format(*color))
    else:
        r, g, b = (round(c / 255 * 5) for c in color)
        codes.append(f"38;5;{16 + 36 * r + 6 * g + b}")
    return "\x1b[" + ";".join(codes) + "m"


def to_ansi(line: Line, caps: Caps) -> str:
    if not caps.color:
        return plain(line)
    out: list[str] = []
    active: Optional[tuple[Optional[RGB], bool]] = None
    for span in line:
        if not span.text:
            continue
        style = (span.color, span.bold)
        # Blanks show no color, so a run of them needs no escape codes.
        if span.text.strip() and style != active:
            if active is not None and active != (None, False):
                out.append("\x1b[0m")
            if span.color or span.bold:
                out.append(_sgr(span.color or INK, span.bold, caps.color))
            active = style
        out.append(span.text)
    if active is not None and active != (None, False):
        out.append("\x1b[0m")
    return "".join(out)


def _mix(a: RGB, b: RGB, t: float) -> RGB:
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))  # type: ignore[return-value]


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


def clock(epoch: int, now: int) -> str:
    moment = datetime.fromtimestamp(epoch)
    time_text = moment.strftime("%H:%M")
    if moment.date() == datetime.fromtimestamp(now).date():
        return time_text
    return f"{moment.month}/{moment.day} {time_text}"


def short_path(path: str) -> str:
    parts = path.split("/")
    return f"…/{'/'.join(parts[-2:])}" if len(parts) > 3 else path


def level_label(level: str, unicode: bool) -> Optional[str]:
    return (LEVEL_TEXT if unicode else LEVEL_TEXT_ASCII).get(level)


# ------------------------------------------------------------------ pieces
def frame(title: str, body: list[Line], width: int, unicode: bool = True) -> list[Line]:
    tl, tr, bl, br, h, v = ("┌", "┐", "└", "┘", "─", "│") if unicode else ("+", "+", "+", "+", "-", "|")
    label = f"[ {title} ]"
    tail = max(width - text_width(label) - 3, 0)
    top: Line = [Span(tl + h, BORDER), Span(label, PURPLE, True), Span(h * tail + tr, BORDER)]
    lines = [top]
    for line in body:
        lines.append([Span(v + " ", BORDER), *fit(line, width - 4), Span(" " + v, BORDER)])
    lines.append([Span(bl + h * (width - 2) + br, BORDER)])
    return lines


def gradient_bar(left_percent: float, width: int, level: str, unicode: bool) -> Line:
    full = round(left_percent / 100 * width)
    # Rounding must not make a nearly empty window look empty, or a nearly
    # full one look full.
    if left_percent > 0:
        full = max(full, 1)
    if left_percent < 100:
        full = min(full, width - 1)
    on, off = ("█", "░") if unicode else ("#", ".")
    tip = LEVEL_COLOR[level]
    base = _mix(tip, BACKGROUND, 0.55)
    cells = [Span(on, _mix(base, tip, i / max(full - 1, 1))) for i in range(full)]
    return [*cells, Span(off * (width - full), TRACK)]


def _header(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    now = snap["generated_at"]
    stamp = datetime.fromtimestamp(now).strftime("%Y-%m-%d %H:%M:%S")
    tz = snap.get("timezone") or ""
    rows = len(BANNER)
    if opts.compact or not opts.unicode or opts.width < BANNER_WIDTH:
        return [[Span("AGENTS//USAGE", PURPLE, True), Span(f"  {stamp} {tz}", MUTED)]]

    online = sum(1 for a in snap["accounts"] if a["windows"] and not a["stale"])
    side: list[Line] = [
        [Span("USAGE //", PURPLE, True), Span(" v" + str(snap.get("version", "")), MUTED)],
        [],
        [Span(stamp[:10], INK)],
        [Span(stamp[11:] + " " + tz, INK)],
        [],
        [Span(f"{online}/{len(snap['accounts'])} 配额在线", INK)],
    ]
    with_side = opts.width >= SIDE_PANEL_MIN_WIDTH
    lines: list[Line] = []
    for i, row in enumerate(BANNER):
        color = _mix(PINK, PURPLE, i / (rows - 1))
        line: Line = [Span(row, color, True)]
        if with_side:
            line = [*line, Span("   "), *side[i]]
        lines.append(line)
    if not with_side:
        lines.append([Span("USAGE // ", PURPLE, True), Span(f"{stamp} {tz}", MUTED)])
    return lines


def _urgent(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    now = snap["generated_at"]
    urgent = snap.get("most_urgent")
    arrow = "▶ " if opts.unicode else "> "
    lines: list[Line] = []
    if urgent:
        level = urgent["level"]
        line: Line = [
            Span(arrow, LEVEL_COLOR[level], True),
            Span("最紧张  ", MUTED),
            Span(f"{urgent['name']} · {urgent['label']} · 剩余 {round(urgent['left_percent'])}%", INK, True),
        ]
        if urgent.get("resets_at"):
            line.append(Span(f" · {duration(urgent['resets_at'] - now)}后重置", MUTED))
        label = level_label(level, opts.unicode)
        if label:
            line.append(Span(f"  {label}", LEVEL_COLOR[level], True))
        lines.append(line)
    else:
        lines.append([Span(arrow, MUTED), Span("暂无可比较的实时配额", MUTED)])
    if urgent and snap.get("unmeasured"):
        lines.append([Span(f"  （未计入：{'、'.join(snap['unmeasured'])}）", MUTED)])
    return lines


def _window_lines(window: dict[str, Any], inner: int, now: int, unicode: bool) -> list[Line]:
    level = window["level"]
    reset_at = window.get("resets_at")
    when = f"{clock(reset_at, now)} 重置" if reset_at else "尚未开始计时"
    rel = f"{duration(reset_at - now)}后" if reset_at else ""
    status = level_label(level, unicode) or ""
    label = Span(pad_text(window["label"], 14 if "(" in window["label"] else 8), INK)
    pct = Span(f"{round(window['left_percent']):>4}%", LEVEL_COLOR[level], True)
    two_rows = inner < 76
    label_width = text_width(label.text)
    # The status column is always reserved, so bars line up across windows.
    fixed = label_width + 5 + 2 + (0 if two_rows else 35 + 8)
    bar = gradient_bar(window["left_percent"], max(inner - 2 - fixed, 8), level, unicode)
    first: Line = [Span("  "), label, *bar, pct]
    detail = [Span(pad_text(when, 17), MUTED), Span(pad_text(rel, 16), MUTED)]
    tag = [Span(" " + status, LEVEL_COLOR[level], True)] if status else []
    if two_rows:
        return [first, [Span(" " * (2 + label_width)), *detail, *tag]]
    return [[*first, Span("  "), *detail, *tag]]


def _quota(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    now = snap["generated_at"]
    inner = opts.width - 4
    body: list[Line] = []
    if not snap["accounts"]:
        body.append([Span("没有检测到已安装的 agent", MUTED)])
    for i, account in enumerate(snap["accounts"]):
        if i:
            body.append([])
        marker = "▸ " if opts.unicode else "> "
        title: Line = [Span(marker, AGENT_COLOR.get(account["agent"], ACCENT), True),
                       Span(account["name"], INK, True)]
        if account.get("plan"):
            title.append(Span(f" · {account['plan'].upper()}", ACCENT))
        if account.get("email"):
            title.append(Span(f" · {account['email']}", MUTED))
        if account.get("stale"):
            title.append(Span("  ◷ 数据已过期" if opts.unicode else "  (stale) 数据已过期", AMBER, True))
        body.append(title)
        for window in account["windows"]:
            body.extend(_window_lines(window, inner, now, opts.unicode))
        if account.get("note"):
            body.extend([Span(f"  {part}", MUTED)] for part in wrap_text(account["note"], inner - 2))
        foot = []
        if account.get("manual_resets"):
            foot.append(f"{account['manual_resets']} 次手动重置可用")
        if account.get("source"):
            foot.append(f"{account['source']} · {duration(now - account['captured_at'])}前")
        if foot:
            body.extend([Span(f"  {part}", MUTED)] for part in wrap_text(" · ".join(foot), inner - 2))
    return frame("配额", body, opts.width, opts.unicode)


def select_rows(snap: dict[str, Any], opts: ViewOptions) -> tuple[list[str], list[dict[str, Any]]]:
    today = datetime.fromtimestamp(snap["generated_at"]).date()
    days = [(today - timedelta(days=i)).isoformat() for i in range(opts.days - 1, -1, -1)]
    rows = [r for r in snap["usage"]["rows"]
            if r["date"] >= days[0] and (opts.agent == "all" or r["agent"] == opts.agent)]
    return days, rows


def _sum(rows: list[dict[str, Any]]) -> dict[str, int]:
    fields = ("fresh", "cache_read", "cache_write", "output", "requests")
    return {f: sum(r[f] for r in rows) for f in fields}


def _stat_lines(rows: list[dict[str, Any]], inner: int) -> list[Line]:
    t = _sum(rows)
    input_side = t["fresh"] + t["cache_read"] + t["cache_write"]
    hit = f"{t['cache_read'] / input_side * 100:.1f}%" if input_side else "—"
    sessions = len({s for r in rows for s in r["sessions"]})
    stats = [
        ("不含缓存读取", compact(METRICS["billable"][1](t))),
        ("全部", compact(METRICS["total"][1](t))),
        ("输出", compact(t["output"])),
        ("缓存命中", hit),
        ("请求", f"{t['requests']:,}"),
        ("会话", f"{sessions:,}"),
    ]
    lines: list[Line] = [[]]
    for label, value in stats:
        item = [Span(f"{label} ", MUTED), Span(value, ACCENT, True), Span("   ")]
        if lines[-1] and line_width(lines[-1]) + line_width(item) > inner:
            lines.append([])
        lines[-1].extend(item)
    return lines


def _daily(days: list[str], rows: list[dict[str, Any]], opts: ViewOptions) -> list[Line]:
    value = METRICS[opts.metric][1]
    by_day: dict[str, dict[str, int]] = {}
    for r in rows:
        day = by_day.setdefault(r["date"], {})
        day[r["agent"]] = day.get(r["agent"], 0) + value(r)
    totals = [sum(by_day.get(d, {}).values()) for d in days]
    peak = max(totals, default=0)
    agents = [a for a in AGENT_NAME if opts.agent in ("all", a)]
    on, off = ("█", "░") if opts.unicode else ("#", ".")
    bar_width = max(opts.width - 4 - 6 - 9, 8)
    lines: list[Line] = []
    for date, total in zip(days, totals):
        cells: Line = []
        used = 0
        running = 0
        for agent in agents:
            amount = by_day.get(date, {}).get(agent, 0)
            if amount > 0:
                # Round the running total: rounding each part separately can
                # add up to more cells than the bar has.
                running += amount
                count = min(max(round(running / peak * bar_width) - used, 1), bar_width - used)
                cells.append(Span(on * count, AGENT_COLOR[agent]))
                used += count
        cells.append(Span(off * max(bar_width - used, 0), TRACK))
        value_text = compact(total) if total else "—"
        lines.append([Span(date[5:].replace("-", "/") + " ", MUTED), *cells,
                      Span(f" {value_text:>7}", INK if total == peak and peak else MUTED, total == peak and peak > 0)])
    # Only agents with usage in range: most people do not run all of them.
    shown = [a for a in agents if any(a in by_day.get(d, {}) for d in days)]
    if len(shown) > 1:
        legend: Line = []
        for agent in shown:
            legend.extend([Span(on * 2, AGENT_COLOR[agent]), Span(f" {AGENT_NAME[agent]}   ", MUTED)])
        lines.append(legend)
    return lines


def _table(title: str, rows: list[dict[str, Any]], key: Callable[[dict[str, Any]], str],
           name: Callable[[str], str], opts: ViewOptions, limit: int = 6) -> list[Line]:
    value = METRICS[opts.metric][1]
    groups: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        groups.setdefault(key(r), []).append(r)
    ordered = sorted(groups.items(), key=lambda kv: value(_sum(kv[1])), reverse=True)
    shown = [(name(k), _sum(v), v[0]["agent"]) for k, v in ordered[:limit]]
    if ordered[limit:]:
        rest = [r for _, v in ordered[limit:] for r in v]
        shown.append((f"其他 {len(ordered) - limit} 项", _sum(rest), None))

    columns = (12, 8, 8)
    inner = opts.width - 4
    name_width = max(inner - sum(columns) - 2, 12)
    metric_label = METRICS[opts.metric][0]
    head = Span(pad_text(title, name_width + 2) + pad_text(metric_label, columns[0], True)
                + pad_text("输出", columns[1], True) + pad_text("请求", columns[2], True), MUTED)
    lines: list[Line] = [[head]]
    dot = "● " if opts.unicode else "* "
    for label, totals, agent in shown:
        cut = fit([Span(label, INK)], name_width)
        lines.append([
            Span(dot, AGENT_COLOR.get(agent, MUTED) if agent else MUTED), *cut,
            Span(pad_text(compact(value(totals)), columns[0], True), ACCENT, True),
            Span(pad_text(compact(totals["output"]), columns[1], True), MUTED),
            Span(pad_text(f"{totals['requests']:,}", columns[2], True), MUTED),
        ])
    return lines


def _usage(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    days, rows = select_rows(snap, opts)
    inner = opts.width - 4
    title = f"用量 · 最近 {opts.days} 天 · {METRICS[opts.metric][0]}"
    if not rows:
        return frame(title, [[Span("所选范围内没有用量记录", MUTED)]], opts.width, opts.unicode)
    body = _stat_lines(rows, inner)
    body.append([])
    body.extend(_daily(days, rows, opts))
    body.append([])
    body.extend(_table("模型", rows, lambda r: f"{r['agent']}\0{r['model']}", lambda k: k.split("\0")[1], opts))
    if opts.projects:
        body.append([])
        body.extend(_table("项目", rows, lambda r: r["project"], short_path, opts, limit=8))
    first = snap["usage"].get("first_date")
    if first and first > days[0]:
        body.append([])
        body.append([Span(f"本地日志最早到 {first}", MUTED)])
    return frame(title, body, opts.width, opts.unicode)


def build_view(snap: dict[str, Any], opts: ViewOptions) -> list[Line]:
    lines = [*_header(snap, opts), [], *_urgent(snap, opts), [], *_quota(snap, opts), *_usage(snap, opts)]
    # Nothing may wrap: the reveal and watch mode both address lines by row.
    return [fit(line, opts.width) if line_width(line) > opts.width else line for line in lines]
