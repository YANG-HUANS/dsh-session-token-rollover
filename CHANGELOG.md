# Changelog

## 1.0.0 — 2026-11-19

首个版本。

- 监听 `turn/end`，用 `tokenMeter.measure()` 判断 token 预算是否耗尽
- 触发条件：用量 ≥ 阈值（`maxTokens` 或 `上下文窗口 × ratio`），或回合以 `max-tokens` 结束
- 继承方式：
  - `digest`：`sessionController.create()` + `prompt()` 交接摘要
  - `fork`：`sessionController.fork()` 复制完整事件前缀
- 新会话继承源会话的 workspace / cwd / agent preset
- 子代理会话、`aborted` / `forked` 回合跳过；同会话每进程只续接一次
- 全部参数可通过 `cordis.patch.yml` 的 `config` 调整