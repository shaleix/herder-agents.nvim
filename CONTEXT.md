# herder-agents.nvim 领域词汇（CONTEXT.md）

评审与实施对话共用的术语。修改概念或新增 module 名时同步更新本表。

- **tool** — 一个 CLI 编码代理（opencode、codex、qoder…）。注册于 `config.options.tools`，有序列表唯一表示是 `config.options.tool_order`。
- **current tool** — 当前操作目标，`config.current_tool()`（`vim.g.ai_tool`，回落 `default_tool`）。
- **pane** — Herdr 终端面板，agent 运行处。pane 生命周期（lookup/find/toggle/interrupt/new_session/replace/relaunch）全部收口在 `panes.lua`。
- **relaunch** — 面板内重启 agent 的固定时序：ctrl+c → 终端复位载荷 → ctrl+c → `pane run` → 轮询前台进程（500ms/60）。唯一实现在 `panes.relaunch`；优雅退出（/quit）与 TERM→KILL 是两种退出策略，汇入同一 relaunch。
- **delivery** — 提示词传输队列（`delivery.lua`）。两条通道：**agent channel**（`herdr agent prompt`，懂 agent 状态机）与 **text channel**（`pane send-text` + 括号粘贴编码 + 提交键）。双通道是 herdr CLI 固有 interface，不是冗余。
- **note** — 锚定在代码行的批注（extmark 跟随编辑），会话内存储；`notes.lua` 是存储，`ui/notes_view.lua` 是评审弹窗。
- **inline input** — 行内输入框，note 编辑与一次性 line prompt 共用。
- **attachment** — 随提示词发送的文件上下文；唯一格式由 `context.files_block`（`Relate file:`）生成。
- **smoke** — `test/smoke.lua`，唯一测试面；假执行器注入 `utils.set_exec`。

## 保留决定（详见 docs/adr/0001）

delivery 双通道、`ui/common.dim`、`context.lua`、`completion/skills.lua` 均通过 deletion test，不删。
