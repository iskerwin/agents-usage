# agents-usage

How much quota Claude Code, Codex and Grok have left, and when it resets, in the macOS menu bar.

The app runs the `agents-usage` command, which reads the data through [agents-meter](https://github.com/iskerwin/agents-meter), a public library that uses the Python standard library only.

## The menu bar app

The overview has each agent's quota windows, the running and idle (dimmed) tasks, and today's and this month's cost. The notch on each meter is where an even pace would be now. Up to five tasks show, and more scroll in the list. Hovering over or clicking an agent opens its details beside the panel, on the right where there is room. The details add manual resets, the data source, requests, sessions and the cache hit rate. Clicking a project opens its folder in Finder, and clicking a task goes to the terminal it runs in. In Rex it goes to the task's tab and pane; for a task in another session, turn on Remote Control in Rex's Settings → Server → Client Info first.

It needs macOS 14 or later and builds with the Command Line Tools alone. There are no prebuilt releases yet. To start it at login, add it in System Settings → General → Login Items.

```bash
uv tool install --force --reinstall .  # the app runs the installed agents-usage: run again after a Python change
macos/build.sh                         # builds into ~/Applications, or the folder you pass
agents-usage --json                    # one full snapshot, for scripts and other panels
uv run --group dev pytest
macos/test.sh
```

The app refreshes every 5 minutes, every 15 seconds while its panel is open, and on wake. It runs with `--claude-live`, because only the usage endpoint gives per-model weekly quotas such as Fable's: an account that has one gets an extra row under Claude Code. At launch it shows the last data, held to the same freshness rules, until the quotas refresh in the background. That data is kept in `~/.cache/agents-meter/snapshot.json` (mode 0600), which holds account emails and project paths.

**Cost is an estimate, not a bill.** Tokens from the logs are priced at [public API rates](https://github.com/iskerwin/agents-meter/blob/main/agents_meter/pricing.py); subscriptions don't pay that way. Models without a public price (such as `grok-4.7-build`) aren't counted; hover over the cost to see them. Long-context and fast-mode surcharges aren't counted either, so it runs a little under real API cost.

Running tasks are the agent processes in terminals. Claude Code's state is its own record; Codex and Grok count as running while their session file was written in the last 2 minutes. A task's title is the short session title the agent wrote, shown only on this machine.

## Where the data comes from

Which logs and endpoints are read, the freshness rules, and the rate limits and 429 backoff are described in [agents-meter](https://github.com/iskerwin/agents-meter#where-the-data-comes-from). Every process on the machine that uses agents-meter, such as [rex-agents](https://github.com/iskerwin/rex-agents) alongside the app, shares Claude's and Grok's rate limits: one query a minute between them all.

## Claude Code's quota

Claude Code's logs hold no quota, so by default only token use shows. Connect it either way:

**The statusLine snapshot (reads no token).** Put the command on your PATH with `uv tool install .`, then add this to your statusLine script:

```bash
input=$(cat)
printf '%s' "$input" | agents-usage capture-claude
# ...then draw the status line from "$input" as before
```

Only `rate_limits` is kept, in `~/.cache/agents-meter/claude-statusline.json` (mode 0600). It goes stale after 10 minutes and is only updated when Claude Code replies.

**`--claude-live` (live, reads the token).** The OAuth token Claude Code stored (`~/.claude/.credentials.json` or the macOS keychain, which may ask) is used to call the endpoint `/usage` calls. The endpoint is undocumented, may change at any time and is rate-limited hard: one call a minute at most, and after an HTTP 429 the wait doubles, up to 15 minutes, or follows `Retry-After`. The token is kept in memory and sent only to `api.anthropic.com`.

## Notice

Unofficial, and not affiliated with Anthropic, OpenAI or xAI. The Claude live quota and the Grok quota come from undocumented endpoints with the tokens stored on this machine, and may stop working at any time; check that this fits each service's terms before you use it.

The menu bar's interface and behavior draw on [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar) (MIT); no code was copied. The Codex and Claude icon paths come from [Simple Icons](https://simpleicons.org) (CC0). The icons and trademarks belong to their owners and are used here only to mark each service.

## License

[MIT](LICENSE)
