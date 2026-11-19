# dsh-session-token-rollover

DeepSeek Harness (DSH) 的 Host 插件：**对话把 token 预算用光时，自动新开一个会话，并把上一个会话的内容继承过去。**

> English: A DSH Host plugin. When a conversation hits its token budget (either the measured request pressure crosses a threshold, or a turn ends with the `max-tokens` finish reason), it opens a **fresh session** and carries the previous conversation over — as a compact handoff digest, or as a full fork.

---

## 为什么需要

长对话撞上上下文上限时的默认结局只有两种：请求被截断，或者模型开始"忘记"开头的内容。DSH 自带的 compression 行不一定挂载；即使挂载，压缩后仍然是同一个会话，记录会越来越乱。

这个插件换一个思路：**把会话当成可滚动的东西**。预算用完，就开一个新的、干净的会话，把上下文接过去，旧的会话原样留档。

## 行为

```
turn/end ──► ctx.tokenMeter.measure(session)
             │
             ├─ tokens >= 阈值          → 触发
             ├─ 结束原因 = max-tokens   → 触发（可关）
             ▼
        mode = digest ─► sessionController.create()  新会话（同 workspace / cwd / preset）
                          → sessionController.prompt() 交接消息
        mode = fork   ─► sessionController.fork()    复制完整事件前缀
```

细节：

- 每个 `turn/end` 结束都量一次当前请求压力；阈值 = `maxTokens`（>0 时），否则 `模型上下文窗口 × ratio`，上下文窗口未知时回退 `fallbackLimitTokens`；
- 子代理会话（`origin: 'subagent'`）默认不参与；`aborted` / `forked` 的回合永远不触发；
- 同一个会话在同一进程内只续接一次，不会连环开新会话；
- `digest` 模式下新会话会挂到源会话所在的 workspace，出现在侧边栏同一个分组里。

## 安装

### 方式 A：本地目录（开发用）

```powershell
# 在 DSH 里调 plugin_manager：
#   action: install_bundle
#   target: E:/path/to/dsh-session-token-rollover
```

`install_bundle` 会把目录以 `link:` 装进当前 profile，并把它加入 `dsh.profile.bundles`，改代码即热重载。

### 方式 B：git / 压缩包

```powershell
# 按你的 DSH 版本选一种：
#   install_bundle target: github:OWNER/dsh-session-token-rollover
#   pnpm add github:OWNER/dsh-session-token-rollover   然后在 dsh.profile.bundles 里加 "dsh-session-token-rollover"
```

也可以先在本地 `npm pack` 出 tgz，再用 `file:` 依赖安装。

### 方式 C：手写一行 patch（不推荐，但最直观）

在 profile 的 `cordis.patch.yml` 末尾追加：

```yaml
- id: session-token-rollover
  name: 'file:///ABS/PATH/index.js'
  config:
    mode: digest
```

没有 `.git` 依赖、没有 pnpm，改完即生效；缺点是绕过了 Plugin Manager，看不到标题和图标。

## 配置

写在 `cordis.patch.yml` 的 `config` 里，全部可省略：

| 字段 | 默认 | 含义 |
|---|---:|---|
| `enabled` | `true` | 总开关 |
| `mode` | `'digest'` | `digest` 摘要交接 / `fork` 全量复制 |
| `maxTokens` | `0` | 绝对阈值；`0` 表示按上下文窗口比例算 |
| `ratio` | `0.85` | 上下文窗口占比阈值 |
| `fallbackLimitTokens` | `100000` | 上下文窗口未知时的阈值 |
| `onMaxTokens` | `true` | 回合以 `max-tokens` 结束时也续接 |
| `allowSubagent` | `false` | 是否允许子代理会话续接 |
| `keepRecent` | `8` | 交接消息携带最近多少条 user/assistant 消息 |
| `maxCharsPerMessage` | `500` | 每条消息的字符上限 |
| `maxTotalChars` | `6000` | 交接消息总字符上限 |
| `autoPrompt` | `true` | 是否把交接消息发进新会话（会触发一次模型回合） |

## 依赖的服务

`inject: ['tokenMeter', 'sessionController']`，`workspaceRegistry` 为可选。缺任何一个，插件不会激活，也不会报错。

## 验证

```powershell
# 把阈值压到 1，随便跑一个回合，看会话目录是否多出一个
# sessions/<workspace>/session-<uuid>/session.v4.jsonl.zstd
```

已在本机实测：一次子代理回合后，会话目录 97 → 99，新增的那个 `session-*` 就是插件开的续接会话。

## 已知限制

- `digest` 模式会往新会话发一条交接消息，**会触发一次模型回合**（少量 token）。想要完全静默设 `autoPrompt: false`，但那时新会话是空的。
- `fork` 模式复制的是同样的上下文压力，通常还得配合压缩使用。
- 交接消息是确定性拼接（不调用模型做摘要），所以它只是"最近几条对话"，不是"要点提炼"。
- 插件重启后"同一会话只续接一次"的记录会清零。

## License

MIT