"""The animated parts: boot log, decrypt reveal and the full-screen watch mode.

These only run on an interactive terminal. The numbers on screen always come
from the snapshot; the effects never show or imply data of their own.
"""

from __future__ import annotations

import random
import select
import shutil
import signal
import sys
import threading
import time
from dataclasses import replace
from typing import Any, Callable, Optional

from agents_usage.render import (
    ACCENT,
    BORDER,
    INK,
    MUTED,
    RED,
    TRACK,
    Caps,
    Line,
    Span,
    ViewOptions,
    _mix,
    build_view,
    char_width,
    fit,
    to_ansi,
)

NARROW_GLYPHS = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜ0123456789<>/\\$#"
WIDE_GLYPHS = "零壹贰叁肆伍陆柒捌玖甲乙丙丁戊己庚辛"
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
REVEAL_FRAMES = 16
REVEAL_FRAME_SECONDS = 0.035
WATCH_FRAME_SECONDS = 0.1
MAX_RAIN_ROWS = 14
HIDE_CURSOR, SHOW_CURSOR = "\x1b[?25l", "\x1b[?25h"
ENTER_ALT, LEAVE_ALT = "\x1b[?1049h", "\x1b[?1049l"

Fetch = Callable[..., dict[str, Any]]


def _write(text: str) -> None:
    sys.stdout.write(text)
    sys.stdout.flush()


def terminal_size() -> tuple[int, int]:
    size = shutil.get_terminal_size((100, 40))
    return size.columns, size.lines


# ------------------------------------------------------------------ boot log
def _boot_lines(steps: dict[str, Optional[str]], tick: int, caps: Caps) -> list[str]:
    lines = []
    for label, detail in steps.items():
        if detail is None:
            mark = [Span(f"[ {SPINNER[tick % len(SPINNER)]}  ] ", ACCENT)]
            lines.append(to_ansi([*mark, Span(label, INK)], caps))
        else:
            mark = [Span("[ OK ] ", ACCENT, True)]
            lines.append(to_ansi([*mark, Span(label, INK), Span(f"  {detail}", MUTED)], caps))
    return lines


def fetch_with_boot(fetch: Fetch, caps: Caps) -> dict[str, Any]:
    """Run the fetch in a thread while its real steps tick by."""
    steps: dict[str, Optional[str]] = {}
    result: dict[str, Any] = {}

    def work() -> None:
        try:
            result["snapshot"] = fetch(on_step=lambda label, detail: steps.__setitem__(label, detail))
        except BaseException as exc:
            result["error"] = exc

    thread = threading.Thread(target=work, daemon=True)
    thread.start()
    _write(HIDE_CURSOR)
    drawn = 0
    tick = 0
    try:
        while thread.is_alive():
            lines = _boot_lines(dict(steps), tick, caps)
            _write((f"\x1b[{drawn}A" if drawn else "") + "".join(f"\r\x1b[K{line}\n" for line in lines))
            drawn = len(lines)
            tick += 1
            thread.join(0.08)
    finally:
        _write((f"\x1b[{drawn}A" if drawn else "") + "\x1b[J" + SHOW_CURSOR)
    if "error" in result:
        raise result["error"]
    return result["snapshot"]


# ------------------------------------------------------------------ reveal
def scrambled(line: Line, row: int, step: int, total: int, width: int) -> Line:
    """`line` with the characters not yet decrypted replaced by glyphs of the
    same cell width. The front sweeps left to right, unevenly per character."""
    out: Line = []
    col = 0
    for span in line:
        for ch in span.text:
            w = char_width(ch)
            jitter = (row * 31 + col * 17) % 5
            threshold = col / max(width, 1) * (total - 5) + jitter
            if ch == " " or step >= threshold:
                out.append(Span(ch, span.color, span.bold))
            else:
                glyph = random.choice(WIDE_GLYPHS if w == 2 else NARROW_GLYPHS)
                out.append(Span(glyph, BORDER))
            col += w
    return out


def print_view(lines: list[Line], caps: Caps, animate: bool) -> None:
    final = [to_ansi(line, caps) for line in lines]
    _, height = terminal_size()
    # Rewinding with cursor-up only works if everything fits on screen.
    if not animate or len(lines) >= height:
        for text in final:
            _write(text + "\n")
            if animate:
                time.sleep(0.008)
        return
    width = max((sum(char_width(c) for s in line for c in s.text) for line in lines), default=1)
    _write(HIDE_CURSOR)
    try:
        for step in range(REVEAL_FRAMES):
            frame = [to_ansi(scrambled(line, row, step, REVEAL_FRAMES, width), caps)
                     for row, line in enumerate(lines)]
            rewind = f"\x1b[{len(lines)}A" if step else ""
            _write(rewind + "".join(f"\r\x1b[K{text}\n" for text in frame))
            time.sleep(REVEAL_FRAME_SECONDS)
        _write(f"\x1b[{len(lines)}A" + "".join(f"\r\x1b[K{text}\n" for text in final))
    finally:
        _write(SHOW_CURSOR)


# ------------------------------------------------------------------ rain
class Rain:
    """Falling glyphs for the empty rows under the panels. Purely decorative."""

    def __init__(self) -> None:
        self.width = 0
        self.rows = 0
        self.drops: list[list[float]] = []

    def _spawn(self, above: bool = True) -> list[float]:
        head = -random.uniform(0, self.rows * 2) if above else random.uniform(0, self.rows)
        return [head, random.uniform(0.25, 0.8), random.randint(3, max(self.rows, 4))]

    def frame(self, width: int, rows: int) -> list[Line]:
        if width != self.width or rows != self.rows:
            self.width, self.rows = width, rows
            self.drops = [self._spawn(False) if random.random() < 0.3 else [] for _ in range(width)]
        grid: list[Line] = [[Span(" ")] * width for _ in range(rows)]
        for col, drop in enumerate(self.drops):
            if not drop:
                if random.random() < 0.004:
                    self.drops[col] = self._spawn()
                continue
            drop[0] += drop[1]
            head, _, length = drop
            if head - length > rows:
                self.drops[col] = []
                continue
            for row in range(max(int(head - length), 0), min(int(head) + 1, rows)):
                fade = (head - row) / length
                color = INK if fade < 0.08 else _mix(ACCENT, TRACK, min(fade, 1.0))
                grid[row][col] = Span(random.choice(NARROW_GLYPHS), color)
        return grid


# ------------------------------------------------------------------ watch
def fit_to_height(lines: list[Line], height: int) -> list[Line]:
    if len(lines) <= height:
        return lines
    return [*lines[:height - 1], [Span("… 终端高度不足，部分内容未显示", MUTED)]]


def compose_watch(snapshot: Optional[dict[str, Any]], opts: ViewOptions, width: int, height: int,
                  footer: Line, rain: Rain) -> list[Line]:
    usable = max(height - 1, 1)
    if snapshot is None:
        body: list[Line] = [[Span("[ 同步中 ]", ACCENT, True)]]
    else:
        wide = replace(opts, width=min(width - 1, 110))  # writing the last column would wrap on some terminals
        body = build_view(snapshot, wide)
        if len(body) > usable:  # a shorter header before anything gets cut
            body = build_view(snapshot, replace(wide, compact=True))
    body = fit_to_height(body, usable)
    gap = usable - len(body)
    rain_rows = min(gap, MAX_RAIN_ROWS)
    filler: list[Line] = [[] for _ in range(gap - rain_rows)]
    drops = rain.frame(width - 1, rain_rows) if rain_rows > 0 else []
    return [*body, *filler, *drops, footer]


class _CbreakInput:
    """Single key presses without echo, so typing cannot garble the screen."""

    def __enter__(self) -> "_CbreakInput":
        self.saved = None
        if sys.stdin.isatty():
            import termios
            import tty
            self.saved = termios.tcgetattr(sys.stdin)
            # TCSANOW: keep pending input, ^C still raises SIGINT in cbreak.
            tty.setcbreak(sys.stdin, termios.TCSANOW)
        return self

    def __exit__(self, *_: Any) -> None:
        if self.saved is not None:
            import termios
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.saved)

    def pressed(self) -> Optional[str]:
        if self.saved is None or not select.select([sys.stdin], [], [], 0)[0]:
            return None
        return sys.stdin.read(1)


def watch(fetch: Fetch, opts: ViewOptions, caps: Caps, interval: int) -> None:
    state: dict[str, Any] = {"snapshot": None, "error": None, "next": 0.0, "busy": True}
    stop = threading.Event()

    def worker() -> None:
        first = True
        while not stop.is_set():
            state["busy"] = True
            try:
                state["snapshot"] = fetch(force=not first)
                state["error"] = None
            except Exception as exc:
                # Keep showing the last good data, and say that it is old.
                state["error"] = str(exc) or type(exc).__name__
            first = False
            state["busy"] = False
            state["next"] = time.time() + interval
            stop.wait(interval)

    def on_term(*_: Any) -> None:
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, on_term)
    threading.Thread(target=worker, daemon=True).start()
    rain = Rain()
    shown: list[str] = []
    tick = 0
    _write(ENTER_ALT + HIDE_CURSOR + "\x1b[2J")
    try:
        with _CbreakInput() as keys:
            while True:
                key = keys.pressed()
                if key in ("q", "Q", "\x03"):
                    return
                width, height = terminal_size()
                if state["busy"]:
                    status = [Span(f"{SPINNER[tick % len(SPINNER)]} 同步中", ACCENT, True)]
                else:
                    left = max(round(state["next"] - time.time()), 0)
                    status = [Span("● LIVE", ACCENT, True), Span(f"  {left}s 后刷新", MUTED)]
                if state["error"]:
                    status.append(Span(f"  刷新失败，显示上次数据：{state['error']}", RED, True))
                footer = [*status, Span("  ·  q 退出", MUTED)]
                lines = compose_watch(state["snapshot"], opts, width, height, footer, rain)
                rendered = [to_ansi(fit(line, width - 1), caps) for line in lines]
                if len(rendered) != len(shown):
                    shown = [""] * len(rendered)
                    _write("\x1b[2J")
                # Rewrite changed lines only: no flicker, little output.
                out = [f"\x1b[{i + 1};1H\x1b[0m{text}\x1b[K" for i, text in enumerate(rendered) if text != shown[i]]
                if out:
                    _write("".join(out))
                shown = rendered
                tick += 1
                time.sleep(WATCH_FRAME_SECONDS)
    except KeyboardInterrupt:
        return
    finally:
        stop.set()
        signal.signal(signal.SIGTERM, previous)
        _write(SHOW_CURSOR + LEAVE_ALT)
