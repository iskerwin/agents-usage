# agents-usage

[English](README.md) | 简体中文

在 macOS 菜单栏查看 Claude Code、Codex 和 Grok 还剩多少额度、什么时候重置。

App 运行 `agents-usage` 命令，后者通过 [agents-meter](https://github.com/iskerwin/agents-meter) 读取数据；agents-meter 是一个公开的库，只用 Python 标准库。

## 菜单栏 App

概览里有每个 agent 的额度窗口、正在运行和空闲（变暗）的任务，以及今天和本月的费用。每个进度条上的刻度表示按匀速消耗此刻应在的位置。最多显示五个任务，更多的在列表里滚动查看。鼠标悬停或点击某个 agent，会在面板旁（有空间时在右侧）展开详情，详情里还有手动重置、数据来源、请求数、会话数和缓存命中率。点击项目会在 Finder 中打开它的文件夹，点击任务会跳到它所在的终端。在 Rex 里会跳到任务所在的标签页和窗格；如果任务在另一个会话里，先在 Rex 的设置 → Server → Client Info 中打开 Remote Control。

需要 macOS 14 或更高版本，只用 Command Line Tools 就能构建。目前还没有预编译的发行版。要开机启动，在系统设置 → 通用 → 登录项中添加它。

```bash
uv tool install --force --reinstall .  # App 运行的是已安装的 agents-usage：改了 Python 代码后要重新运行
macos/build.sh                         # 构建到 ~/Applications，或你传入的文件夹
agents-usage --json                    # 一份完整快照，供脚本和其他面板使用
uv run --group dev pytest
macos/test.sh
```

App 每 5 分钟刷新一次，面板打开时每 15 秒刷新一次，唤醒时也会刷新。它带 `--claude-live` 运行，因为只有用量接口能给出按模型区分的每周额度，例如 Fable 的：有这项额度的账号会在 Claude Code 下多一行。启动时先按同样的新鲜度规则显示上次的数据，额度在后台刷新。这些数据保存在 `~/.cache/agents-meter/snapshot.json`（权限 0600），其中包含账号邮箱和项目路径。

**费用是估算，不是账单。** 日志中的 token 按[公开 API 价格](https://github.com/iskerwin/agents-meter/blob/main/agents_meter/pricing.py)计价，订阅并不按这种方式付费。没有公开价格的模型（例如 `grok-4.7-build`）不计入，悬停在费用上可以看到它们。长上下文和 fast mode 的加价也不计入，所以会比实际 API 费用略低。

正在运行的任务是终端里的 agent 进程。Claude Code 的状态来自它自己的记录；Codex 和 Grok 在会话文件最近 2 分钟内有写入时算作运行中。任务标题是 agent 写下的简短会话标题，只在本机显示。

## 数据来源

读取哪些日志和接口、新鲜度规则、限流和 429 退避，见 [agents-meter](https://github.com/iskerwin/agents-meter/blob/main/README.zh-CN.md#数据来源)。本机所有使用 agents-meter 的进程，例如与 App 同时运行的 [rex-agents](https://github.com/iskerwin/rex-agents)，共享 Claude 和 Grok 的限流：加起来每分钟只查询一次。

## Claude Code 的额度

Claude Code 的日志里没有额度信息，所以默认只显示 token 用量。用下面任一方式接入：

**statusLine 快照（不读取 token）。** 先用 `uv tool install .` 把命令装到 PATH，然后在 statusLine 脚本里加上：

```bash
input=$(cat)
printf '%s' "$input" | agents-usage capture-claude
# ...然后照旧用 "$input" 绘制状态栏
```

只保存 `rate_limits`，位于 `~/.cache/agents-meter/claude-statusline.json`（权限 0600）。10 分钟后过期，只在 Claude Code 回复时更新。

**`--claude-live`（实时，读取 token）。** 用 Claude Code 保存的 OAuth token（`~/.claude/.credentials.json` 或 macOS 钥匙串，可能会弹窗询问）调用 `/usage` 所用的接口。该接口没有公开文档，随时可能变化，并且限流很严：最多每分钟一次，返回 HTTP 429 后等待时间翻倍，最长 15 分钟，或者遵循 `Retry-After`。token 只保存在内存里，只发送到 `api.anthropic.com`。

## 声明

非官方项目，与 Anthropic、OpenAI 和 xAI 无关。Claude 实时额度和 Grok 额度来自未公开的接口，使用本机保存的 token，随时可能失效；使用前请确认符合各服务的条款。

菜单栏的界面和交互参考了 [ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)（MIT），没有复制代码。Codex 和 Claude 的图标路径来自 [Simple Icons](https://simpleicons.org)（CC0）。图标和商标归各自所有者，这里只用来标识各服务。

## 许可证

[MIT](LICENSE)
