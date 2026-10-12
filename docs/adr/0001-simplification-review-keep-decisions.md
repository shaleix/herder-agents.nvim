# ADR-0001: 简化评审中的保留决定

- 状态:已接受
- 日期:2026-10-12

## 背景

2026-10 的架构简化评审（6 候选全部实施，见 git log `232ef84..99ce330`）识别出一批通过 deletion test 的模块。记录保留理由，避免未来评审重新提议删除。

## 决定

1. **delivery.lua 双通道保留。** agent channel（`herdr agent prompt`）与 text channel（`pane send-text` + 括号粘贴编码）是 herdr CLI 固有的两条 interface,不是插件侧冗余;`agent_channel = false` 是真实的第二 adapter。smoke 352-499 全矩阵覆盖。合并会丢掉「server 懂 agent 状态机、可拒绝阻塞提交」的能力。
2. **ui/common.lua 保留。** `dim()` 是 deep module（refcount 背景、绑定 buffer 生命周期），README 记载的 seam;删除会让 refcount 逻辑在调用方复现。
3. **context.lua 保留。** 四种上下文格式器（selection/files/notes/diagnostics）集中一处,4 个模块消费,深度合格。
4. **completion/skills.lua 保留。** 合格的 blink.cmp adapter（缓存、pending-flush、v1/v2 兼容）。
5. **tool_cmds 保留为独立配置通道。** 与 `tools.<name>.cmd`（默认值）和 `vim.g.ai_tool_cmd`（运行时覆盖）职责不同;合并属 breaking 且收益仅省一个 key。解析序:`vim.g.ai_tool_cmd > tool_cmds > tools[name].cmd`。

## 后果

- 未来评审不再对上述四模块提议删除/合并,除非 herdr CLI 本身改变（第 1 条）。
- `tools.<name>.cmd` 已由死配置变为生效回退（`31ad8c5`）;hermes 默认以 `hermes --tui` 启动,与文档一致。
