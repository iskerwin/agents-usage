"""The full-screen watch mode."""

from __future__ import annotations

import select
import shutil
import signal
import sys
import threading
import time
from dataclasses import replace
from typing import Any, Callable, Optional

from agents_usage.render import (
    CRITICAL,
    MAX_WIDTH,
    MUTED,
    Line,
    Span,
    ViewOptions,
    build_view,
    fit,
    to_ansi,
)

WATCH_FRAME_SECONDS = 0.1
HIDE_CURSOR, SHOW_CURSOR = "\x1b[?25l", "\x1b[?25h"
ENTER_ALT, LEAVE_ALT = "\x1b[?1049h", "\x1b[?1049l"

Fetch = Callable[..., dict[str, Any]]


def _write(text: str) -> None:
    sys.stdout.write(text)
    sys.stdout.flush()


def terminal_size() -> tuple[int, int]:
    size = shutil.get_terminal_size((MAX_WIDTH, 40))
    return size.columns, size.lines


def compose_watch(snapshot: Optional[dict[str, Any]], error: Optional[str], opts: ViewOptions,
                  width: int, height: int) -> list[Line]:
    """Exactly `height` rows, the last kept for a failed refresh."""
    usable = max(height - 1, 1)
    # Writing the last column would wrap on some terminals.
    view = replace(opts, width=min(width - 1, MAX_WIDTH))
    body = build_view(snapshot, view)[:usable] if snapshot else [[Span("读取中", MUTED)]]
    footer: Line = [Span(f"刷新失败：{error}", CRITICAL, True)] if error else []
    return [*body, *[[] for _ in range(usable - len(body))], footer]


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


def watch(fetch: Fetch, opts: ViewOptions, color: bool, interval: int) -> None:
    state: dict[str, Any] = {"snapshot": None, "error": None}
    stop = threading.Event()

    def worker() -> None:
        first = True
        while not stop.is_set():
            try:
                state["snapshot"] = fetch(force=not first)
                state["error"] = None
            except Exception as exc:
                # Keep showing the last good data, and say that it is old.
                state["error"] = str(exc) or type(exc).__name__
            first = False
            stop.wait(interval)

    def on_term(*_: Any) -> None:
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, on_term)
    threading.Thread(target=worker, daemon=True).start()
    shown: list[str] = []
    _write(ENTER_ALT + HIDE_CURSOR + "\x1b[2J")
    try:
        with _CbreakInput() as keys:
            while True:
                if keys.pressed() in ("q", "Q", "\x03"):
                    return
                width, height = terminal_size()
                lines = compose_watch(state["snapshot"], state["error"], opts, width, height)
                rendered = [to_ansi(fit(line, width - 1), color) for line in lines]
                if len(rendered) != len(shown):
                    shown = [""] * len(rendered)
                    _write("\x1b[2J")
                # Rewrite changed lines only: no flicker, little output.
                out = [f"\x1b[{i + 1};1H\x1b[0m{text}\x1b[K" for i, text in enumerate(rendered) if text != shown[i]]
                if out:
                    _write("".join(out))
                shown = rendered
                time.sleep(WATCH_FRAME_SECONDS)
    except KeyboardInterrupt:
        return
    finally:
        stop.set()
        signal.signal(signal.SIGTERM, previous)
        _write(SHOW_CURSOR + LEAVE_ALT)
