# herder-agents.nvim 领域词汇（CONTEXT.md）

评审与实施对话共用的术语。修改概念或新增 module 名时同步更新本表。

- **tool** — 一个 CLI 编码代理（opencode、codex、qoder…）。注册于 `config.options.tools`，有序列表唯一表示是 `config.options.tool_order`。
- **current tool** — 当前操作目标，`config.current_tool()`（`vim.g.ai_tool`，回落 `default_tool`）。
- **pane** — Herdr 终端面板，agent 运行处。pane 生命周期（lookup/find/toggle/interrupt/new_session/replace/relaunch）全部收口在 `panes.lua`。
- **agent target** — herdr agent 子命令接受的寻址标识；本插件使用 pane_id（`wX:p2`），agent name 可选且可能缺失。
- **herdr mention** — prompt 文本里的 `herdr:<pane_id> (workspace:kind)` 引用语法，用来指代一个 herdr agent；括号内是该 agent 的 workspace 名与 kind。
- **workspace 域限定** — 提及补全与 `panes.find_tool_pane` 的候选仅限与 nvim 同一 herdr workspace 的 agent/pane（`utils.current_workspace_id()` 只读 pane 内注入的 `HERDR_WORKSPACE_ID`，无 CLI 回退）；解析不到（nvim 不在 herdr 内）时不过滤（fail-open，沿用 status.lua 先例）。数据层 `agents.list` 保持全量，策略只收口在关联点；delivery 拿显式 pane_id 投递，不做拦截。
- **relaunch** — 面板内重启 agent 的固定时序：ctrl+c → 终端复位载荷 → ctrl+c → `pane run` → 轮询前台进程（500ms/60）。唯一实现在 `panes.relaunch`；优雅退出（/quit）与 TERM→KILL 是两种退出策略，汇入同一 relaunch。
- **delivery** — 提示词传输队列（`delivery.lua`）。两条通道：**agent channel**（`herdr agent prompt`，懂 agent 状态机）与 **text channel**（`pane send-text` + 括号粘贴编码 + 提交键）。双通道是 herdr CLI 固有 interface，不是冗余。
- **note** — 锚定在代码行的批注（extmark 跟随编辑），会话内存储；`notes.lua` 是存储，`ui/notes_view.lua` 是评审弹窗。
- **inline input** — 行内输入框，note 编辑与一次性 line prompt 共用。
- **attachment** — 随提示词发送的文件上下文；唯一格式由 `context.files_block`（`Relate file:`）生成。
- **skill source** — skill 补全列表来源（`tools.<name>.skills`）：api 模式（CLI JSON）或 fs 模式（user/project 目录 + SKILL.md frontmatter，向上到仓库根）；api 与 fs 可共存，api 失败自动回退 fs 并告警一次；api 经临时文件中转（上游管道截断，opencode#52925）；获取层收口在 `skills.lua`，`completion/skills.lua` 仅是 blink 适配层。
- **LLM adapter** — extraction 调 LLM 的可插拔接口，唯一实现收口在 `llm.lua`；内置默认为 OpenAI 兼容 HTTP（DeepSeek 开箱，`DEEPSEEK_API_KEY`），不依赖任何 LLM 插件（llm.nvim 系补全型插件无任意 prompt API）。
- **extraction** — 把 agent 终端输出规范化为标准问题 JSON（status/question/options/multiple/suggested）的 LLM 步骤；输入经 `herdr agent read --lines N` 捕获，编排收口在 `question.lua`。
- **read-more loop** — extraction 的判别式追读循环：模型返回 `need_more` 时扩大读取行数重试（上限 2 轮），`complete` 才出表单；不用 tool_calls（tools 与 response_format 互斥、可移植性差）。
- **question form** — agent 提问的弹窗表单（`ui/question_form.lua`）：space 切换选项（单选 radio / 多选 checkbox，由提取结果 `multiple` 决定，`suggested` 默认选中）、ctrl+enter 提交、esc 取消；提交文本 = 选中项原文逐行 + 自定义行原样（无模板前缀；多问题时按 `Qk:` 分块、块间空行），经 delivery **text channel** 送回（agent blocked 时 agent channel 拒收）。`:AIQuestion` 触发即弹同布局 **loading 骨架**（阶段文案：捕获/提取/追读/重试 + esc 取消丢弃迟到结果），完成后原位变身表单，不关窗重开。高度/宽度按 `question_form.height_ratio`/`width_ratio` 固定（全形态同尺寸，morph 零几何跳变）。**多问题分节**：提取结果 `questions[]` 每题一节——`❓ <label>` header（label = 终端原文里的原始标号，无则回退 Q{k}；题干剥掉与 label 匹配的编号前缀，编号由 header 承载不重复）、选项、desc 说明行（选项区后空行隔开、节尾）；节间 `---` 分割线；任一题无选中项即拦截提交。**自定义答案**：`a` 唤起底部输入（按题绑定、预填旧内容、Esc 保草稿），Enter 后**升级为该题的正式选项**（追加在原选项后，再编辑则原位更新、选中态保持），与普通选项同权参与 radio/checkbox/导航/提交——图例常显「a 自定义输入」。提交分块与未答/提示优先用 label、无则回退数组位置——终端编号不从 1 开始时提交不错位。上框 `filetype=markdown` + `buftype=nofile`：语法高亮生效、渲染类插件（markview 等）不 attach。
- **answer state** — question form 的作答状态机（`ui/question_form/state.lua`，纯函数集、表进表出）：spec 归一化（normalize_question）、form→form 延续匹配（题干逐字匹配、原选项文本+索引相同才继承选中、自定义选项恒映射到 n_base+1、radio 只保最低已选项）、选项切换与自定义答案升级、提交文本组装（compose_questions：N=1 无前缀，N>1 按 label 分块、无 label 回退 Qk）。
- **line model** — question form 的行模型（`ui/question_form/rows.lua`）：作答态 + 固定内容宽度 → 渲染行序列（节头/题干折行/选项 ✓ 字形/建议标记/desc/分割线/fallback 原文）；双宽字符折行测量（dw/wrap_dw）收口于此。纯函数、spec 直测。
- **visible files** — 当前 agent 的**可见视口**里出现的真实文件（`file:line[:col]` 位置一并保留）：从 pane 画面文本提取、只收录磁盘上存在的常规文件（提取逻辑参考 termscope），fzf-lua 挑选直达；视口里没有路径时回退仓库文件列表。
- **spec** — 测试面（仿 neogit）：`make test` → `tests/init.lua` 用 plenary test_harness 跑 `tests/specs/herder-agents/**/*_spec.lua`（每个 spec 一个独立 headless nvim，`minimal_init.lua` 只装 rtp）；单文件用 `TEST_FILES=… make test`；共享工具在 `tests/util/util.lua`，`check` 断言迁移为 plenary `assert.truthy`，假执行器注入 `utils.set_exec` 不变。

## 保留决定（详见 docs/adr/0001）

delivery 双通道、`ui/common.dim`、`context.lua`、`completion/skills.lua` 均通过 deletion test，不删。
