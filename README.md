# agents-usage

Claude Code、Codex、Grok 还剩多少额度，什么时候重置。

macOS 菜单栏 app，背后是 `agents-usage` 命令。数据由 [agents-meter](https://github.com/iskerwin/agents-meter) 读取，它是只依赖 Python 标准库的公开库。

## macOS 菜单栏

概览页是每个 agent 的额度表、运行中和空闲（变淡）的任务，以及今日和本月费用。长条上的刻度是匀速用量此刻应剩的位置。任务最多显示 5 行，更多的在列表内滚动。悬浮或点击 agent 会在旁边打开详情面板，优先开在右侧；详情里还有手动重置次数、数据来源、请求数、会话数和缓存命中率。点项目在 Finder 打开目录，点任务跳到它所在的终端；在 Rex 里会定位到对应的标签和面板，任务在其他会话时，要在 Rex 的“设置 → Server → Client Info”中打开 Remote Control 才能切换过去。

需要 macOS 14 及以上，只装 Command Line Tools 即可构建，目前不提供预编译版本。需要开机启动时，在“系统设置 → 通用 → 登录项”中添加。

```bash
uv tool install --force --reinstall .  # app 调用已安装的 agents-usage，Python 代码改动后要重新运行
macos/build.sh                         # 构建到 ~/Applications，也可以传入其他目录
agents-usage --json                    # 一次完整快照，给脚本和其他面板用
uv run --group dev pytest
macos/test.sh
```

app 每 5 分钟刷新一次，面板打开时每 15 秒刷新一次，电脑唤醒后也会刷新。app 开启 `--claude-live`，因为 Fable 等按模型计的每周额度只有用量接口提供；账号有这类额度时，Claude Code 下多出一行，没有时不显示。启动时先显示上次的数据（按同样的规则标记过期），配额在后台刷新后再更新。上次的数据保存在 `~/.cache/agents-meter/snapshot.json`（权限 0600），包含账号邮箱和项目路径。

**费用是估算，不是账单。** 这里按[公开 API 价](https://github.com/iskerwin/agents-meter/blob/main/agents_meter/pricing.py)把日志里的 Token 折算成美元，订阅用户并不按这个价格付费。没有公开价的模型（如 `grok-4.7-build`）不计入，悬停费用可以看到。长上下文和快速模式的加价不计入，所以会略低于实际 API 费用。

运行任务来自终端里的 agent 进程：Claude Code 用它自己记录的状态，Codex 和 Grok 在会话文件 2 分钟内有写入时算运行中。任务标题是 agent 生成的会话短标题，只显示在本机。

## 数据来源

读取哪些日志和接口、新鲜度规则、限流与 429 退避见 [agents-meter](https://github.com/iskerwin/agents-meter#where-the-data-comes-from)。Claude 和 Grok 的限流状态由本机所有用 agents-meter 的进程共用（例如同时开着 [rex-agents](https://github.com/iskerwin/rex-agents)），一分钟内合计只查询一次。

## 接入 Claude Code 配额

Claude Code 的日志里没有配额信息，所以默认只显示 Token 趋势。两种接入方式任选其一：

**statusLine 快照（不读取 token）。** 先运行 `uv tool install .` 把命令装到 PATH，再在你的 statusLine 脚本里加入：

```bash
input=$(cat)
printf '%s' "$input" | agents-usage capture-claude
# ……继续用 "$input" 渲染状态栏
```

快照只保存 `rate_limits`，写入 `~/.cache/agents-meter/claude-statusline.json`（权限 0600）。超过 10 分钟会标记为过期，只在 Claude Code 回复时更新。

**`--claude-live`（实时，需要读取 token）。** 读取 Claude Code 保存的 OAuth token（`~/.claude/.credentials.json` 或 macOS 钥匙串，可能弹出授权），调用 `/usage` 使用的接口。该接口未公开，可能随时变化，并且限流严格，所以每 60 秒最多调用一次；收到 HTTP 429 后间隔翻倍，最长 15 分钟，或按 `Retry-After`。token 只保存在内存中，只发送给 `api.anthropic.com`。

## 声明

非官方工具，与 Anthropic、OpenAI 和 xAI 无关。Claude 实时配额和 Grok 配额用的是未公开接口，并会读取本机的登录 token，可能随时失效；使用前请自行确认是否符合各服务的条款。

菜单栏的接口和行为参考了 [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)（MIT），未复制其代码。Codex 和 Claude 的图标路径来自 [Simple Icons](https://simpleicons.org)（CC0），各图标和商标归其所有者，这里只用来标识对应的服务。

## 许可证

[MIT](LICENSE)
