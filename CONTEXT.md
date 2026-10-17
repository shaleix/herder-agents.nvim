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
- **skill source** — skill 补全列表来源（`tools.<name>.skills`）：api 模式（CLI JSON）或 fs 模式（user/project 目录 + SKILL.md frontmatter，向上到仓库根）；api 与 fs 可共存，api 失败自动回退 fs 并告警一次；api 经临时文件中转（上游管道截断，opencode#52925）；获取层收口在 `skills.lua`，`completion/skills.lua` 仅是 blink 适配层。
- **LLM adapter** — extraction 调 LLM 的可插拔接口，唯一实现收口在 `llm.lua`；内置默认为 OpenAI 兼容 HTTP（DeepSeek 开箱，`DEEPSEEK_API_KEY`），不依赖任何 LLM 插件（llm.nvim 系补全型插件无任意 prompt API）。
- **extraction** — 把 agent 终端输出规范化为标准问题 JSON（status/question/options/multiple/suggested）的 LLM 步骤；输入经 `herdr agent read --lines N` 捕获，编排收口在 `question.lua`。
- **read-more loop** — extraction 的判别式追读循环：模型返回 `need_more` 时扩大读取行数重试（上限 2 轮），`complete` 才出表单；不用 tool_calls（tools 与 response_format 互斥、可移植性差）。
- **question form** — agent 提问的弹窗表单（`ui/question_form.lua`）：space 切换选项（单选 radio / 多选 checkbox，由提取结果 `multiple` 决定，`suggested` 默认选中）、ctrl+enter 提交、esc 取消；提交文本 = 选中项原文逐行 + 自定义行原样（无模板前缀；多问题时按 `Qk:` 分块、块间空行），经 delivery **text channel** 送回（agent blocked 时 agent channel 拒收）。`:AIQuestion` 触发即弹同布局 **loading 骨架**（阶段文案：捕获/提取/追读/重试 + esc 取消丢弃迟到结果），完成后原位变身表单，不关窗重开。高度/宽度按 `question_form.height_ratio`/`width_ratio` 固定（全形态同尺寸，morph 零几何跳变）。**多问题分节**：提取结果 `questions[]` 每题一节、节间 `---` 分割线、每题内嵌 ✎ 自定义答案行（底部输入区按题重绑定）；任一题未答（0 选中且自定义空）拦截提交。每题可携带 **label**（终端原文里的原始标号，如 "Q2"）：提交分块与未答/重绑定提示优先用它、无则回退数组位置——终端编号不从 1 开始时提交不错位。上框 `filetype=markdown` + `buftype=nofile`：语法高亮生效、渲染类插件（markview 等）不 attach。
- **smoke** — `test/smoke.lua`，唯一测试面；假执行器注入 `utils.set_exec`。

## 保留决定（详见 docs/adr/0001）

delivery 双通道、`ui/common.dim`、`context.lua`、`completion/skills.lua` 均通过 deletion test，不删。
