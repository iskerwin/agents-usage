import json
import subprocess
import sys
from datetime import datetime, timedelta

import pytest

from agents_usage.render import (
    Caps,
    Span,
    ViewOptions,
    build_view,
    compact,
    fit,
    gradient_bar,
    line_width,
    plain,
    select_rows,
    text_width,
    to_ansi,
)
from agents_usage.tui import Rain, scrambled

NOW = int(datetime(2026, 11, 4, 12, 0).timestamp())


def date_ago(days):
    return (datetime.fromtimestamp(NOW).date() - timedelta(days=days)).isoformat()


def window(label="5 小时", left=90.0, level="ok"):
    return {"label": label, "used_percent": 100 - left, "left_percent": left, "level": level, "resets_at": NOW + 7200}


def row(days=0, agent="claude", model="m-a", project="~/p", fresh=10, cache_read=1000, cache_write=5, output=20,
        requests=2, sessions=(0,)):
    return {"date": date_ago(days), "agent": agent, "model": model, "project": project, "fresh": fresh,
            "cache_read": cache_read, "cache_write": cache_write, "output": output, "requests": requests,
            "sessions": list(sessions)}


def snapshot(**over):
    base = {
        "version": "0.1.0", "generated_at": NOW, "timezone": "CST",
        "accounts": [
            {"agent": "claude", "name": "Claude Code", "plan": "pro", "email": None, "windows": [], "source": None,
             "captured_at": None, "stale": False, "note": "尚未接入配额", "manual_resets": None},
            {"agent": "codex", "name": "Codex", "plan": "team", "email": None, "windows": [window()],
             "source": "codex app-server", "captured_at": NOW, "stale": False, "note": None, "manual_resets": 2},
        ],
        "most_urgent": {"agent": "codex", "name": "Codex", **window()},
        "unmeasured": ["Claude Code"],
        "usage": {"rows": [row(), row(1, "codex", "m-b", "~/q"), row(30)], "first_date": date_ago(30),
                  "last_date": date_ago(0)},
    }
    return {**base, **over}


def view_text(snap=None, **opts):
    lines = build_view(snap or snapshot(), ViewOptions(**opts))
    return "\n".join(plain(line) for line in lines), lines


@pytest.mark.parametrize("value,expected", [
    (120e6, "120M"), (100e3, "100K"), (1e6, "1M"), (2.5e6, "2.5M"), (999, "999"),
    (1234, "1.23K"), (10e9, "10B"), (0, "0"),
])
def test_compact_keeps_trailing_zeros_of_integers(value, expected):
    assert compact(value) == expected


def test_cjk_counts_as_two_cells():
    assert text_width("配额ab") == 6


def test_fit_is_exact_even_cutting_through_cjk():
    for width in range(1, 12):
        assert line_width(fit([Span("配额配额配额配额")], width)) == width


@pytest.mark.parametrize("width", [60, 72, 80, 100, 110])
def test_every_frame_line_has_the_same_width(width):
    _, lines = view_text(width=width, projects=True)
    framed = [line for line in lines if plain(line)[:1] in ("┌", "│", "└")]
    assert framed
    assert {line_width(line) for line in framed} == {width}


def test_missing_quota_is_explained_not_shown_as_a_number():
    text, _ = view_text()
    assert "尚未接入配额" in text
    assert "未计入：Claude Code" in text


@pytest.mark.parametrize("left,level,tag", [(35.0, "low", "▲ 偏低"), (15.0, "critical", "■ 紧张")])
def test_levels_carry_a_text_label(left, level, tag):
    snap = snapshot(most_urgent={"agent": "codex", "name": "Codex", **window(left=left, level=level)})
    snap["accounts"][1]["windows"] = [window(left=left, level=level)]
    text, _ = view_text(snap, width=100)
    assert text.count(tag) == 2


def test_stale_account_is_labelled_and_not_counted_online():
    snap = snapshot()
    snap["accounts"][1]["stale"] = True
    text = view_text(snap)[0]
    assert "数据已过期" in text
    assert "0/2 配额在线" in text


def test_bar_never_rounds_to_empty_or_full():
    def filled(left):
        return sum(1 for span in gradient_bar(left, 20, "ok", True) if span.text == "█")
    assert filled(0.4) == 1
    assert filled(99.9) == 19
    assert filled(100) == 20
    assert filled(0) == 0


def test_stacked_day_bar_never_overflows_when_both_parts_round_up():
    rows = [row(agent="claude", fresh=0, cache_write=0, output=505), row(agent="codex", fresh=0, cache_write=0, output=505),
            row(1, fresh=0, cache_write=0, output=1000)]
    snap = snapshot(usage={"rows": rows, "first_date": date_ago(1), "last_date": date_ago(0)})
    for width in range(60, 111):
        text, lines = view_text(snap, width=width)
        assert "…" not in text
        assert {line_width(l) for l in lines if plain(l)[:1] == "│"} == {width}


def test_days_and_agent_filter_rows():
    assert len(select_rows(snapshot(), ViewOptions(days=7))[1]) == 2
    assert len(select_rows(snapshot(), ViewOptions(days=7, agent="codex"))[1]) == 1
    assert len(select_rows(snapshot(), ViewOptions(days=31))[1]) == 3


def test_stats_add_up_and_sessions_are_distinct():
    rows = [row(fresh=100, cache_read=900, cache_write=0, output=50, sessions=(1, 2)),
            row(1, fresh=100, cache_read=900, cache_write=0, output=50, sessions=(2, 3))]
    text, _ = view_text(snapshot(usage={"rows": rows, "first_date": date_ago(1), "last_date": date_ago(0)}))
    assert "不含缓存读取 300" in text and "全部 2.1K" in text
    assert "缓存命中 90.0%" in text and "会话 3" in text


def test_empty_range_says_so():
    empty = {"rows": [], "first_date": None, "last_date": None}
    assert "没有用量记录" in view_text(snapshot(usage=empty))[0]


def test_no_color_output_has_no_escape_codes():
    _, lines = view_text()
    assert all("\x1b" not in to_ansi(line, Caps(color=0)) for line in lines)
    assert any("\x1b[" in to_ansi(line, Caps(color=24)) for line in lines)
    assert any("38;5;" in to_ansi(line, Caps(color=256)) for line in lines)


def test_ascii_mode_avoids_box_and_block_characters():
    text, _ = view_text(unicode=False)
    for ch in "█░┌│└▸●▶":
        assert ch not in text


def test_scramble_keeps_layout_and_ends_on_the_real_text():
    line = [Span("配额 90% ok", (1, 2, 3))]
    assert line_width(scrambled(line, 3, 0, 16, 20)) == line_width(line)
    assert plain(scrambled(line, 3, 16, 16, 20)) == plain(line)


def test_rain_fills_exactly_the_requested_area():
    rain = Rain()
    for _ in range(30):
        lines = rain.frame(40, 5)
        assert len(lines) == 5
        assert all(line_width(line) == 40 for line in lines)


def run_cli(tmp_path, *args):
    env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin", "XDG_CACHE_HOME": str(tmp_path / "c")}
    return subprocess.run([sys.executable, "-m", "agents_usage.cli", *args], capture_output=True, text=True,
                          env=env, timeout=30)


def test_piped_output_is_plain_and_json_parses(tmp_path):
    done = run_cli(tmp_path)
    assert done.returncode == 0 and "\x1b" not in done.stdout
    assert json.loads(run_cli(tmp_path, "--json").stdout)["version"]


def test_watch_refuses_a_pipe(tmp_path):
    assert run_cli(tmp_path, "--watch").returncode == 2
