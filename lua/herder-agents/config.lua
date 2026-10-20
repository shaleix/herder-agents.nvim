---@mod herder-agents.config 配置

local M = {}

-- 默认 herdr 工具的切换器顺序（table 字面量的 pairs 顺序不确定，显式维护）
M.default_tool_order = { "opencode", "qodercli", "crush", "omp", "pi", "codex", "hermes" }

M.defaults = {
  -- 初始工具（运行期用 <leader>ht / :AISwitch 切换，状态存 vim.g.ai_tool）
  default_tool = "opencode",

  -- CLI 工具在外部 pane 改文件，buffer 自动重载（原配置行为）
  autoread = true,

  -- herdr pane 中运行的 CLI 工具注册表（与默认表按 key 合并，新增工具只需加一项）：
  --   cmd           pane 启动命令（默认与 name 相同）
  --   title         prompt 输入弹窗标题
  --   paste_wrap    发送文本用 bracketed paste 包裹（TUI 支持时开启，防多行被逐行提交）
  --   interrupt_key 中断按键（默认 ctrl+c）；可为 table 表示多键序列，
  --                 逐键间隔发送（如 opencode 的 { "esc", "esc" } 两段式中断）
  --   new_cmd       新会话命令（默认 /clear；codex/opencode 的会话重置命令是 /new）
  --   mode_switch   agent 模式切换（<leader>hM 经 herdr 发送，不同 agent 不同指令）：
  --                   { keys = { "shift+tab" } } 发逻辑按键（herdr pane send-keys）
  --                   { cmd = "/approvals" }     发命令文本并回车
  --                 可选 focus = true：发送后把 herdr 焦点跳到该 pane
  --                 （指令打开 pane 内对话框、需要上下键选择时使用）
  --                 未配置时该工具不支持切换（仅提示）。示例：
  --                   claude = { mode_switch = { keys = { "shift+tab" } } } -- 循环权限模式
  --   model_switch  模型切换（<leader>hm；未配置/置 false 关闭 models 时的兜底行为），
  --                 格式同 mode_switch。示例：
  --                   快捷循环最近模型 = { keys = { "f2" } }   -- model.cycle_recent
  --   models        模型切换候选（<leader>hm 主通道，配置驱动）：两级
  --                 { [provider] = { model, ... } }，选择时平铺为 "provider/model"
  --                 单层列表在 nvim 内选择（fzf-lua 优先，否则 vim.ui.select）；
  --                 model 串可带 #variant 后缀原样传递。选中后按 model_apply 应用
  --   model_apply   选中候选后的应用方式："api"（原地切换，opencode 默认：经
  --                 `opencode api post /api/session/{id}/model` 直接改当前会话
  --                 的模型，与 pane 内 ctrl+x m 对话框同源，agent working 中
  --                 也可切，对后续 turn 生效）/ nil（默认：优雅退出 → 按
  --                 model_resume 模板重启 resume，见 model_restart.lua）
  --   model_resume  重启命令模板（argv 数组），占位符 {session} {provider} {model}；
  --                 命令由 herdr pane run 逐字输入 pane 内 shell 执行，含空格/引号
  --                 的参数需自带 shell 引号（参考 codex 默认模板的 -m/-c 写法）
  --   session_source 会话 id 捕获方式："codex"（herdr agent_session + 退出提示
  --                 兜底）/"opencode"（api session.list 按 pane 目录 + 标题匹配）/
  --                 nil（不捕获；模板不能含 {session}）
  --   quit_cmd      优雅退出命令（默认 "/quit"；opencode 的 /quit 是 /exit 别名）
  --   skills        skill 补全列表来源（herder_skills source，按当前工具取数，
  --                 获取层见 skills.lua；未配置 → 该工具无 skill 补全）：
  --                   trigger       触发字符（默认 "@"；qodercli/pi 用 "/"）
  --                   label_prefix  补全 label 前缀（默认 ""；pi 的斜杠命令是
  --                                 /skill:<name>，故前缀配 "skill:"）
  --                   api = { argv }          CLI JSON 列表模式（响应 {data:[...]}）
  --                   user / project(+project_up)  文件系统发现模式：递归找
  --                                 <目录>/SKILL.md（frontmatter 的 name/
  --                                 description 可覆盖目录名）；project_up 时
  --                                 project 目录从 cwd 向上逐层搜到 git 根
  --                 api 与 user/project 可共存：api 拉取失败自动回退 fs 目录
  --                 扫描并告警一次（CLI 大响应经管道偶发截断的现场兜底）
  tools = { -- opencode: 与 omp 一样用 Esc 中断；ctrl+c 只会清空输入框（双击则退出）。
    -- opencode TUI 的中断是两段式：第一次 Esc 进入待确认态（提示 "ESC again to
    -- interrupt"），第二次 Esc 才真正中断，故默认序列发送两个 esc（单键即中断的
    -- 版本多发一个也无害：中断后 session_interrupt 失效，Esc 只会关弹层）
    opencode = {
      title = " OpenCode Chat ",
      paste_wrap = true,
      interrupt_key = { "esc", "esc" },
      new_cmd = "/new",
      -- opencode v2：agent.cycle 默认 shift+tab（循环 build/plan）；v2 里 tab 是补全键！
      -- v1 时代的 agent_cycle 才是 tab，用 v1 的话改成 { keys = { "tab" } }
      mode_switch = { keys = { "shift+tab" } },
      -- 默认通道：opencode v2 的 leader(ctrl+x) + model.list(<leader>m) 打开
      -- 模型对话框，需在 pane 内上下键选择 → focus 跳转焦点过去；
      -- 选中即会话内实时生效（不重启会话）
      model_switch = { keys = { "ctrl+x", "m" }, focus = true },
      -- 模型切换主通道（可选，默认不配置）：两级 models 平铺单选（<leader>hm），
      -- 选中后经下方 model_apply 原地生效。provider 键与 `opencode models`
      -- 输出的前缀一致；配置后即取代上面的对话框兜底，示例：
      -- models = {
      --   ["zhipuai-coding-plan"] = { "glm-5.3", "glm-5.3#high", "glm-5.3-flash" },
      --   opencode = { "mimo-v2.6-flash-free" },
      -- },
      session_source = "opencode",
      -- <leader>hm 主通道走 API 原地切换（POST /api/session/{id}/model，与
      -- pane 内 ctrl+x m 对话框同源）：选中候选即对当前会话生效，不退出重启，
      -- agent working 中也可切（对后续 turn 生效）。若想走退出重启，把此项
      -- 置 nil 并配置 model_resume 模板即可（注意 v2.0.19 的 TUI 顶层不认 -m）
      model_apply = "api",
      -- skill 补全（"@" 触发）：api 主通道 + fs 目录扫描回退（见下）
      skills = {
        -- 主通道：v2 API（含 builtin/插件 skill）。CLI 大响应经管道偶发截断
        -- （退出码 0 但 JSON 不完整），失败时自动回退下面的目录扫描并告警一次
        api = { "opencode", "api", "skill.list" },
        -- 回退/目录约定（opencode.ai/docs/skills，含 claude/agents 兼容目录）
        user = { "~/.config/opencode/skills", "~/.claude/skills", "~/.agents/skills" },
        project = { ".opencode/skills", ".claude/skills", ".agents/skills" },
        project_up = true,
      },
    },
    -- qodercli：技能以 /skill-name 斜杠命令调用（"/" 触发，label 即 id）；
    -- 目录约定：用户级 ~/.agents/skills 与 ~/.qoder/skills（官方文档位置），
    -- 项目级 .qoder/skills（仅 cwd 一层）
    qodercli = {
      title = " Qoder CLI Chat ",
      paste_wrap = true,
      skills = {
        trigger = "/",
        user = { "~/.agents/skills", "~/.qoder/skills" },
        project = { ".qoder/skills" },
      },
    },
    crush = { title = " Crush Chat " },
    -- omp: Esc interrupts the running agent; Ctrl+C only clears the editor
    -- (double Ctrl+C shuts omp down), so never send ctrl+c there.
    omp = { title = " Oh My Pi Chat ", interrupt_key = "esc" },
    -- pi：技能以 /skill:<name> 斜杠命令调用（"/" 触发 + label 前缀 "skill:"）；
    -- 目录约定：用户级 ~/.pi/agent/skills 与 ~/.agents/skills，项目级
    -- .pi/skills 与 .agents/skills 从 cwd 向上逐层搜到 git 根
    pi = {
      title = " Pi Chat ",
      skills = {
        trigger = "/",
        label_prefix = "skill:",
        user = { "~/.pi/agent/skills", "~/.agents/skills" },
        project = { ".pi/skills", ".agents/skills" },
        project_up = true,
      },
    },
    codex = {
      title = " Codex CLI Chat ",
      paste_wrap = true,
      new_cmd = "/new",
      mode_switch = { cmd = "/approvals", focus = true }, -- 审批模式选择器（pane 内操作，跳转焦点）
      -- 模型切换主通道：两级 models 平铺单选 → /quit 退出 → codex resume 重启。
      -- provider 键与 ~/.codex/config.toml 的 [model_providers.<键>] 一致，示例：
      -- models = {
      --   openai = { "gpt-6-astra", "gpt-5.6-sol" },
      --   ZAI = { "glm-5.3" },
      -- },
      session_source = "codex",
      -- -m/-c 的值自带 shell 引号（pane run 逐字输入 shell 执行）
      model_resume = {
        "codex",
        "resume",
        "{session}",
        "-m",
        "'{model}'",
        "-c",
        "'model_provider=\"{provider}\"'",
      },
    },
    hermes = { title = " Hermes CLI Chat ", cmd = "hermes --tui" },
  },

  -- 静态的项目级启动命令覆盖（运行期设 vim.g.ai_tool_cmd = { codex = "..." } 依旧生效，
  -- 两者同时存在时 vim.g 优先，与原配置一致）
  tool_cmds = {},

  -- herdr 分屏参数
  split = { direction = "right", ratio = 0.55 },

  -- 宽度 toggle（:HerdrShrinkToggle / keys.shrink_toggle）的收窄锚点：
  -- nvim pane 占其所属 split 内容宽（标准布局即全 tab 宽）的目标比例
  -- （与 pane 数量无关）；再按恢复默认分屏比例（上面的 split.ratio），
  -- 两锚点固定来回切换
  toggle_ratio = 0.32,

  -- 切换工具（<leader>ht / :AISwitch）时关闭当前 agent，并在原 pane 重启新工具
  --（类似 codex model 切换流程，herdr 布局原位保持；旧 agent working/blocked 时需先中断）。
  -- 置 false 则只切换目标工具标记（旧行为，两个 agent pane 并存）
  switch_replace = true,

  -- prompt 历史文件（按 cwd 分键；保持与原配置相同路径，历史可共用）
  history_file = "/tmp/cc_prompt_history.json",

  -- prompt 输入弹窗尺寸
  chat_size = { width = 85, height = 35 },

  -- 输入弹窗（aider-input filetype）补全：默认注册 blink.cmp 的 herder_skills
  -- （按当前工具的 tools.<name>.skills 取 skill 列表，见 skills.lua）、
  -- herder_agents（herdr:<pane_id> 提及补全：herdr agent list 的会话级 agent
  -- 列表，5s 缓存，见 agents.lua）与 herder_path（复用 blink.cmp 内置 path
  -- source，按 cwd 补全文件路径）
  completion = {
    enabled = true,
    skill_ttl = 300, -- skill 列表缓存秒数（按工具 + cwd 分键缓存）
  },

  icons = {
    folder = "",
    collapse_marks = { "", "" },
    -- 备注在源缓冲区侧栏的 sign 图标：󰆈 nf-md-comment_text（U+F0188，对话气泡+文本行），
    -- 用字节转义避免编辑时丢失私有区字符。置空字符串则不显示 sign，仅保留行尾预览。
    -- 备选：气泡 󰅺 = "\243\176\133\186" (U+F017A) · 线框气泡 󰆂 = "\243\176\134\130" (U+F0182)
    --       线框气泡文本 󰆉 = "\243\176\134\137" (U+F0189) · 双气泡对话 󰊌 = "\243\176\138\140" (U+F028C)
    note = "\243\176\134\136",
  },

  -- Buffer 备注（<leader>hn 在光标行 / 可视选区添加，Chat 弹窗勾选后随 prompt 发送）
  notes = {
    -- 行尾虚拟文本预览的最大显示宽度（字符数，超出截断为 …）
    preview_width = 40,
    -- 提交给 agent 的注释块标题：用指令句明确"这些 review 注释需要修改"
    submit_header = "Please address these code review comments:",
  },

  -- prompt 投递（借鉴 codex.nvim terminal.lua 的 pending_sends / composer-ready 机制，
  -- 并优先使用 herdr 的 agent 集成原语，见 herdr-nvim 的用法）：
  -- - 提交：herdr agent prompt（服务端按回车、理解状态机、blocked 拒绝）
  -- - 等待：herdr agent wait --until idle/working（状态机精确等待）
  -- 仅对 herdr 已注册的 agent pane 生效；自定义工具 / 未注册 pane / codex /queue
  --（tab 提交）/ append-only 回退到 pane send-text + bracketed paste 旧路径。
  -- agent 未就绪（pane 刚分出还在 shell、TUI 启动中）时排队，就绪后自动投递；
  -- 投递成败以 herdr CLI 退出码判定，失败保留草稿
  delivery = {
    enabled = true,
    -- 提交优先走 herdr agent 集成（agent prompt / agent wait）；置 false 则
    -- 全部走 send-text 旧路径（escape hatch，不影响排队与退出码判定）
    agent_channel = true,
    poll_interval_ms = 300, -- 文本通道的就绪轮询间隔
    settle_ms = 300, -- 就绪后的稳定等待，避开 TUI 初始化窗口
    warn_after_ms = 5000, -- 排队超过该时长提醒一次（不丢弃，持续等待）
    pane_gone_retries = 3, -- process-info 连续失败次数 → 判定 pane 已关闭，丢弃队列
    agent_wait_chunk_ms = 2000, -- agent wait 分段超时（服务端等待的轮询粒度）
  },

  -- agent 提问表单（:AIQuestion）的 LLM 提取（llm.lua / question.lua，ADR-0002）：
  -- 捕获 agent 终端 → OpenAI 兼容端点提取标准问题 JSON → 表单作答（文本通道送回）
  llm = {
    enabled = true, -- false 时 :AIQuestion 跳过提取，直接开 fallback 表单
    base_url = "https://api.deepseek.com",
    api_key_env = "DEEPSEEK_API_KEY",
    model = "deepseek-chat",
    timeout_ms = 30000,
    temperature = 0,
    start_lines = 80, -- 首次捕获的终端行数（need_more 时翻倍重读）
    max_read_more = 2, -- read-more loop 轮数上限（need_more → 翻倍重读重提）
    retries = 1, -- 无效 JSON / HTTP 失败的重试次数（重试附上次失败原因）
    adapter = nil, -- 自定义提取通道：fun(opts, cb)，opts 见 llm.lua（测试注入 / 社区 adapter）
    -- 请求定制（语义仿 neogit ai_commit 的 extra_body / extra_headers / disable_thinking）
    extra_body = nil, -- 追加字段：最后 force 深合并进 chat/completions 请求体、覆盖一切内置字段
                      -- （vLLM/DashScope 等关思考：{ chat_template_kwargs = { enable_thinking = false } }）；
                      -- 与 disable_thinking 预设同时存在时 extra_body 赢
    extra_headers = nil, -- 追加 HTTP 头（table<string, string|number|boolean>，网关按头控流时用）
    disable_thinking = false, -- 按 base_url 厂商预设自动注入关思考字段
                              -- （ollama/deepseek/dashscope/openrouter/openai）；未知端点不注入，
                              -- 改用 extra_body 显式配置
  },

  -- agent 提问表单弹窗尺寸（ui/question_form/ 读取）：固定高度 = 编辑器行数 ×
  -- height_ratio、固定宽度 = 编辑器列数 × width_ratio（收敛到 [56, 88]），
  -- 全形态同尺寸、morph 零几何跳变；缺失时 UI 自带 0.6 / 0.7 缺省
  -- on_show = fun(ctx)：题面「显示完成」回调——form/fallback 都算（loading 态
  -- 不触发；每次新的显示触发一次，form→form 重问再触发；space 切换等重渲染
  -- 不重复触发；触发点在初始光标/focus 应用之后）：
  --   ctx = { mode = "form"|"fallback",   -- 形态（fallback 时 questions 为空表）
  --           questions = {…},            -- 归一化后的题表
  --           win = 题面 winid,           -- 关窗后失效
  --           buf = 题面 bufnr,
  --           input_win = 输入行 winid,   -- 关窗后失效
  --           input_buf = 输入行 bufnr }
  --   winid 关窗后失效；用户自建 namespace 的 extmark 不受组件重渲染影响
  --   （组件只清自有 ns）。典型用途：改 winhighlight / conceallevel / 加自定义
  --   extmark，例如
  --     on_show = function(ctx) vim.wo[ctx.win].conceallevel = 0 end
  --   回调抛错仅 warn、不影响表单；随后发 User "AIQuestionShown"（data 同 ctx）
  question_form = { height_ratio = 0.6, width_ratio = 0.7, on_show = nil },

  -- 发送给 agent 的选区上下文上限（借鉴 codex.nvim：超限拒绝而非静默截断）
  context = {
    max_lines = 500,
    max_bytes = 65536,
  },

  -- agent 状态轮询 → User 事件（AIAgentWorking / AIAgentIdle / AIAgentBlocked，
  -- payload 在 event.data）。每 tick 起一个 herdr 子进程，默认关闭，按需开启；
  -- 开启后可做 "agent 完成 → 自动 format / 关 pane" 之类的自动化
  status_poll = {
    enabled = false,
    interval_ms = 2000,
  },

  -- 用户命令名（置 false 关闭对应命令；:AIToggle 供 worktree_hook.sh 等外部脚本调用；
  -- :AIDropQueue 丢弃排队中的 prompt，见 delivery.enabled）
  commands = {
    toggle = "AIToggle",
    switch = "AISwitch",
    drop_queue = "AIDropQueue",
    shrink_toggle = "HerdrShrinkToggle",
    question = "AIQuestion", -- agent 提问表单（捕获 → LLM 提取 → 表单作答）
    question_dev = "AIQuestionDev", -- 开发：本地文件 / 当前 buffer 驱动提问表单（提交不投递；弹窗测试 / 提示词调优）
    visible_files = "AIVisibleFiles", -- 当前 agent pane 可见视口内的文件挑选（fzf-lua）
  },

  -- 快捷键：默认【不绑定任何快捷键】，由用户显式传入才注册。每项独立配置完整
  -- lhs，可任意混用前缀（如 toggle 用 <leader>ox、input 用 <leader>he）。值支持：
  --   string  完整 lhs，如 "<leader>ho"（mode 用该功能的默认值）
  --   table   { "<leader>ai", mode = { "n", "i" }, desc = "自定义描述" }
  --   false   显式关闭（与不传等价）
  -- 不想走本配置项的，也可以不传 keys，直接用 API 自行 vim.keymap.set（见 README）
  keys = {
    -- toggle / visible_files 的默认 mode 为 n；input 为 n + x（x 预填选区上下文）；
    -- switch 为 n；其余均为 n + x
    -- toggle = "<leader>ho",
    -- input = "<leader>he",
    -- interrupt = "<leader>hx",
    -- new_session = "<leader>hc",
    -- history = "<leader>hh",
    -- switch = "<leader>ht",
    -- read_buffer = "<leader>hR", -- 当前缓冲区加入只读附件
    -- add_buffer = "<leader>ha", -- 当前缓冲区加入可编辑附件
    -- note = "<leader>hn", -- 在光标行 / 可视选区添加备注
    -- line_prompt = "<leader>hp", -- 在光标行 / 可视选区内联输入 prompt，C-Enter 直发 agent
    -- notes_view = "<leader>hr", -- Notes 审阅/提交弹窗（<CR> 发送 / <C-a> 追加不回车）
    -- switch_mode = "<leader>hM", -- 切换 agent 模式（按工具的 mode_switch 配置发送）
    -- model = "<leader>hm", -- 切换模型（models 配置驱动重启 / model_switch 兜底）
    -- question = "<leader>hq", -- agent 提问表单：捕获 → LLM 提取 → 表单作答（:AIQuestion 同效）
    -- visible_files = "<leader>hv", -- 打开当前 agent 可见视口里出现的文件（fzf-lua，保留 file:line:col）
    -- shrink_toggle = "<leader>h<", -- 宽度 toggle：nvim 与 agent 分界在 toggle_ratio 与默认分屏比例（split.ratio）间切换
  },
}

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

-- setup 之前 require 本模块也能拿到默认值
M.options = deep_copy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", M.defaults, opts)

  -- 计算 herdr 工具的确定顺序：默认序在前，用户新增的按字母序追加
  local order = {}
  local seen = {}
  for _, name in ipairs(M.default_tool_order) do
    if M.options.tools[name] then
      table.insert(order, name)
      seen[name] = true
    end
  end
  local extras = {}
  for name in pairs(M.options.tools) do
    if not seen[name] then
      table.insert(extras, name)
    end
  end
  table.sort(extras)
  vim.list_extend(order, extras)
  M.options.tool_order = order
end

---@param name string
---@return string|nil cmd 启动命令（vim.g.ai_tool_cmd 优先于 tool_cmds，再回落 tools[name].cmd）
function M.tool_cmd(name)
  local overrides = vim.g.ai_tool_cmd
  if type(overrides) == "table" and overrides[name] then
    return overrides[name]
  end
  return M.options.tool_cmds[name] or (M.options.tools[name] or {}).cmd
end

---@return string 当前工具（vim.g.ai_tool，未设置时回落 default_tool）
function M.current_tool()
  return vim.g.ai_tool or M.options.default_tool
end

---@param name string
---@return boolean ok 未注册（不在 tool_order）时通知并返回 false
function M.set_current_tool(name)
  if not vim.tbl_contains(M.options.tool_order or {}, name) then
    vim.notify("Unknown AI tool: " .. name, vim.log.levels.ERROR, { title = "Herder Agents" })
    return false
  end
  vim.g.ai_tool = name
  vim.notify("AI tool switched to: " .. name, vim.log.levels.INFO)
  return true
end

-- 取某功能当前绑定的 lhs（用于错误/提示消息，如 "use <leader>ho first"）；
-- 未绑定时返回 fallback
---@param action string
---@param fallback string
---@return string
function M.key_hint(action, fallback)
  local spec = M.options.keys[action]
  if type(spec) == "string" then
    return spec
  end
  if type(spec) == "table" and type(spec[1]) == "string" then
    return spec[1]
  end
  return fallback
end

return M
