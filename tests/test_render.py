import json
import subprocess
import sys
from datetime import datetime, timedelta

import pytest

from agents_usage.render import (
    Span,
    ViewOptions,
    bar,
    build_view,
    compact,
    fit,
    line_width,
    plain,
    select_rows,
    text_width,
    to_ansi,
)
from agents_usage.tui import compose_watch

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


@pytest.mark.parametrize("width", [40, 60, 72])
def test_nothing_is_wider_than_the_view(width):
    _, lines = view_text(width=width, projects=True)
    assert max(line_width(line) for line in lines) <= width


def test_missing_quota_is_explained_not_shown_as_a_number():
    assert "尚未接入配额" in view_text()[0]


@pytest.mark.parametrize("left,level,mark", [(35.0, "low", "▲ 35%"), (15.0, "critical", "■ 15%")])
def test_levels_carry_a_mark(left, level, mark):
    snap = snapshot()
    snap["accounts"][1]["windows"] = [window(left=left, level=level)]
    assert view_text(snap)[0].count(mark) == 1


def test_stale_account_is_labelled():
    snap = snapshot()
    snap["accounts"][1]["stale"] = True
    assert "已过期" in view_text(snap)[0]


def test_bar_never_rounds_to_empty_or_full():
    def filled(fraction):
        return bar(fraction, 20, None, True)[0].text.count("█")
    assert filled(0.004) == 1
    assert filled(0.999) == 19
    assert filled(1) == 20
    assert filled(0) == 0


def test_days_and_agent_filter_rows():
    assert len(select_rows(snapshot(), ViewOptions(days=7))[1]) == 2
    assert len(select_rows(snapshot(), ViewOptions(days=7, agent="codex"))[1]) == 1
    assert len(select_rows(snapshot(), ViewOptions(days=31))[1]) == 3


def test_range_total_follows_the_metric():
    rows = [row(fresh=100, cache_read=900, cache_write=0, output=50),
            row(1, fresh=100, cache_read=900, cache_write=0, output=50)]
    snap = snapshot(usage={"rows": rows, "first_date": date_ago(1), "last_date": date_ago(0)})
    assert "最近 7 天  300" in view_text(snap)[0]
    assert "最近 7 天 · 全部 Token  2.1K" in view_text(snap, metric="total")[0]


def test_ranking_folds_the_tail_without_losing_tokens():
    rows = [row(model=f"m{i}", fresh=10, cache_write=0, output=0) for i in range(8)]
    text = view_text(snapshot(usage={"rows": rows, "first_date": date_ago(0), "last_date": date_ago(0)}))[0]
    assert "其他 2 项" in text
    assert text.splitlines()[-1].endswith("20")


def test_empty_range_says_so():
    empty = {"rows": [], "first_date": None, "last_date": None}
    assert "没有用量记录" in view_text(snapshot(usage=empty))[0]


def test_no_color_output_has_no_escape_codes():
    _, lines = view_text()
    assert all("\x1b" not in to_ansi(line, False) for line in lines)
    assert any("\x1b[" in to_ansi(line, True) for line in lines)


def test_color_ends_with_its_span():
    assert to_ansi([Span("a", "31", True), Span("b")], True) == "\x1b[1;31ma\x1b[0mb"


def test_ascii_mode_avoids_block_characters():
    snap = snapshot()
    snap["accounts"][1]["windows"] = [window(left=15.0, level="critical")]
    text, _ = view_text(snap, unicode=False)
    assert "!! 15%" in text
    for ch in "█░▲■":
        assert ch not in text


@pytest.mark.parametrize("height", [2, 5, 60])
def test_watch_fills_the_screen_and_reports_failure_on_the_last_row(height):
    lines = compose_watch(snapshot(), "boom", ViewOptions(), 73, height)
    assert len(lines) == height
    assert "boom" in plain(lines[-1])
    assert plain(compose_watch(snapshot(), None, ViewOptions(), 73, height)[-1]) == " " * 72


def test_watch_says_when_it_has_nothing_yet():
    lines = compose_watch(None, None, ViewOptions(), 73, 3)
    assert [plain(line).rstrip() for line in lines] == ["读取中", "", ""]
    # Every row spans the screen but the last column, which would wrap on some terminals.
    assert {line_width(line) for line in lines} == {72}


def run_cli(tmp_path, *args):
    env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin", "XDG_CACHE_HOME": str(tmp_path / "c")}
    return subprocess.run([sys.executable, "-m", "agents_usage.cli", *args], capture_output=True, text=True,
                          env=env, timeout=30)


def test_piped_output_is_plain_and_json_parses(tmp_path):
    done = run_cli(tmp_path)
    assert done.returncode == 0 and "\x1b" not in done.stdout
    assert json.loads(run_cli(tmp_path, "--json").stdout)["version"]


def test_no_anim_still_works_for_old_scripts(tmp_path):
    assert run_cli(tmp_path, "--no-anim").returncode == 0


def test_watch_refuses_a_pipe(tmp_path):
    assert run_cli(tmp_path, "--watch").returncode == 2
