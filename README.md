# agents-usage

Claude Code、Codex、Grok 还剩多少额度，什么时候重置。

```bash
uv run agents-usage                  # 配额 + 最近 7 天用量
uv run agents-usage --watch          # 全屏刷新（默认 60 秒），按 q 退出
uv run agents-usage --watch 30       # 每 30 秒刷新
uv run agents-usage --days 30        # 统计最近 30 天
uv run agents-usage --agent codex    # claude / codex / grok / all
uv run agents-usage --metric total   # billable（默认）/ total / output
uv run agents-usage --projects       # 同时显示项目明细
uv run agents-usage --json           # 完整数据，给脚本和 agent 用
uv run --group dev pytest
```

`uv tool install .` 后可以在任意目录直接运行 `agents-usage`。终端视图使用终端自身的配色，`--no-color` 或 `NO_COLOR` 关闭颜色，输出到管道时是纯文本。只依赖 Python 标准库。

## macOS 菜单栏

概览页是每个 agent 的额度表、运行中和空闲（变淡）的任务，以及今日和本月费用。长条上的刻度是匀速用量此刻应剩的位置。任务最多显示 5 行，更多的在列表内滚动。悬浮或点击 agent 会在旁边打开详情面板，优先开在右侧；详情里还有手动重置次数、数据来源、请求数、会话数和缓存命中率。点项目在 Finder 打开目录，点任务跳到它所在的终端；在 Rex 里会定位到对应的标签和面板，任务在其他会话时，要在 Rex 的“设置 → Server → Client Info”中打开 Remote Control 才能切换过去。

需要 macOS 14 及以上，只装 Command Line Tools 即可构建，目前不提供预编译版本。需要开机启动时，在“系统设置 → 通用 → 登录项”中添加。

```bash
uv tool install --force --reinstall .  # app 调用已安装的 agents-usage，Python 代码改动后要重新运行
macos/build.sh                         # 构建到 ~/Applications，也可以传入其他目录
macos/test.sh
```

app 每 5 分钟刷新一次，面板打开时每 15 秒刷新一次，电脑唤醒后也会刷新。app 开启 `--claude-live`，因为 Fable 等按模型计的每周额度只有用量接口提供；账号有这类额度时，Claude Code 下多出一行，没有时不显示。启动时先显示上次的数据（按同样的规则标记过期），配额在后台刷新后再更新。上次的数据保存在 `~/.cache/agents-usage/snapshot.json`（权限 0600），包含账号邮箱和项目路径。

**费用是估算，不是账单。** 这里按[公开 API 价](agents_usage/pricing.py)把日志里的 Token 折算成美元，订阅用户并不按这个价格付费。没有公开价的模型（如 `grok-4.7-build`）不计入，悬停费用可以看到。长上下文和快速模式的加价不计入，所以会略低于实际 API 费用。

运行任务来自终端里的 agent 进程：Claude Code 用它自己记录的状态，Codex 和 Grok 在会话文件 2 分钟内有写入时算运行中。任务标题是 agent 生成的会话短标题，只显示在本机。

## 数据来源

| 内容 | Claude Code | Codex | Grok |
|---|---|---|---|
| Token 趋势 | `~/.claude/projects/**/*.jsonl` | `~/.codex*/sessions`、`archived_sessions` | `~/.grok/sessions/*/*/usage.json` |
| 配额窗口 | statusLine 快照，或 `--claude-live` | `codex app-server`，失败时用会话日志中最新的记录 | Grok CLI 用量接口 |

- 只读取时间、模型、工作目录、Token 数和 agent 生成的会话标题，不读取消息内容。
- 历史范围取决于 agent 保留日志的时长。Claude Code 默认会清理旧日志。
- 同一响应的重复日志行、恢复或分叉会话的重放记录都会去重。
- 不含缓存读取时，三者口径一致：Codex 和 Grok 的输入 Token 已包含缓存，这里先拆开再统计。

## 接入 Claude Code 配额

Claude Code 的日志里没有配额信息，所以默认只显示 Token 趋势。两种接入方式任选其一：

**statusLine 快照（不读取 token）。** 先运行 `uv tool install .` 把命令装到 PATH，再在你的 statusLine 脚本里加入：

```bash
input=$(cat)
printf '%s' "$input" | agents-usage capture-claude
# ……继续用 "$input" 渲染状态栏
```

快照只保存 `rate_limits`，写入 `~/.cache/agents-usage/claude-statusline.json`（权限 0600）。超过 10 分钟会标记为过期，只在 Claude Code 回复时更新。

**`--claude-live`（实时，需要读取 token）。** 读取 Claude Code 保存的 OAuth token（`~/.claude/.credentials.json` 或 macOS 钥匙串，可能弹出授权），调用 `/usage` 使用的接口。该接口未公开，可能随时变化，并且限流严格，所以每 60 秒最多调用一次。token 只保存在内存中，只发送给 `api.anthropic.com`。

## 接入 Grok 配额

存在 `~/.grok/auth.json`（运行 `grok login` 后生成）时自动接入。这里读取其中的 token，调用 Grok CLI 使用的用量接口。该接口未公开，可能随时变化，所以每 60 秒最多调用一次。token 只保存在内存中，只发送给 `cli-chat-proxy.grok.com`，本工具不会写入这个文件。token 的有效期是 6 小时，过期时运行一次 `grok models`（不启动会话），由 Grok CLI 自己续期；续期失败时保留上次的数据并标记过期。

## 规则

- 缺失的值保持缺失，不会显示成 0% 或 100%。
- 已过重置时间的窗口会被隐藏；过期的快照会被标记，也不参与“最紧张”的判断。
- 不会为了刷新用量而启动 agent 会话，不会使用手动重置次数，也不会改变任何限额。
- 剩余 ≤40% 标记 ▲，≤20% 标记 ■。

## 声明

非官方工具，与 Anthropic、OpenAI 和 xAI 无关。Claude 实时配额和 Grok 配额用的是未公开接口，并会读取本机的登录 token，可能随时失效；使用前请自行确认是否符合各服务的条款。

配额部分的思路和新鲜度规则参考了 [aiusage](https://github.com/sergestack/aiusage)（MIT），菜单栏的接口和行为参考了 [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)（MIT），未复制其代码。Codex 和 Claude 的图标路径来自 [Simple Icons](https://simpleicons.org)（CC0），各图标和商标归其所有者，这里只用来标识对应的服务。

## 许可证

[MIT](LICENSE)
