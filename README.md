# agents-usage

在终端里集中查看 AI coding agent（Claude Code、Codex、Grok）的配额和 Token 用量，黑客风格，Dracula 配色。

配额部分的思路和新鲜度规则参考了 [aiusage](https://github.com/sergestack/aiusage)（MIT），菜单栏的接口和行为参考了 [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)（MIT），未复制其代码。只依赖 Python 标准库。

这是非官方工具，与 Anthropic、OpenAI 和 xAI 无关。Claude 实时配额和 Grok 配额用的是未公开接口，并会读取本机的登录 token，可能随时失效；使用前请自行确认是否符合各服务的条款。

```bash
uv run agents-usage                  # 配额 + 最近 7 天用量
uv run agents-usage --watch          # 全屏刷新（默认 60 秒）+ 字符雨，按 q 退出
uv run agents-usage --watch 30       # 每 30 秒刷新
uv run agents-usage --days 30        # 统计最近 30 天
uv run agents-usage --agent codex    # claude / codex / grok / all
uv run agents-usage --metric total   # billable（默认）/ total / output
uv run agents-usage --projects       # 同时显示项目明细
uv run agents-usage --json           # 机器可读
uv run --group dev pytest
```

`uv tool install .` 后可以在任意目录直接运行 `agents-usage`。

启动日志、解密动画和字符雨只在交互式终端中出现，不影响任何数字。`--no-anim` 关闭动画，`--no-color` 或 `NO_COLOR` 关闭颜色。输出到管道时是不带动画和颜色的纯文本。配色按 Dracula 深色背景（`#282A36`）设计。

## macOS 菜单栏

菜单栏显示最紧张窗口的剩余百分比，点开是配额、按月的用量热力图和可展开的历史总量。毛玻璃和外观默认跟随系统，可以在面板底部手动选择亮色或暗色，热力图固定用 Dracula 紫。需要 macOS 14 及以上，只装 Command Line Tools 即可构建。

```bash
uv tool install --force --reinstall .  # app 调用已安装的 agents-usage，Python 代码改动后要重新运行
macos/build.sh                         # 构建到 ~/Applications，也可以传入其他目录
macos/test.sh
```

目前不提供预编译版本，需要自行构建。app 每 5 分钟刷新一次，不开启 `--claude-live`。Claude 配额依赖上面的 statusLine 快照，超过 10 分钟未更新会标记为“已过期”。需要开机启动时，在“系统设置 → 通用 → 登录项”中添加。

## 数据来源

| 内容 | Claude Code | Codex | Grok |
|---|---|---|---|
| Token 趋势 | `~/.claude/projects/**/*.jsonl` | `~/.codex*/sessions`、`archived_sessions` | `~/.grok/sessions/*/*/usage.json` |
| 配额窗口 | statusLine 快照，或 `--claude-live` | `codex app-server`，失败时用会话日志中最新的记录 | Grok CLI 用量接口 |

- 只读取时间、模型、工作目录和 Token 数，不保留消息内容。
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
- 剩余 ≤40% 标记“偏低”，≤20% 标记“紧张”。

## 许可证

[MIT](LICENSE)
