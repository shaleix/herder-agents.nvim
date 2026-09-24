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
  --   interrupt_key 中断按键（默认 ctrl+c）
  --   new_cmd       新会话命令（默认 /clear；codex/opencode 的会话重置命令是 /new）
  tools = {
    -- opencode: 与 omp 一样用 Esc 中断运行中的 agent；ctrl+c 只会清空输入框（双击则退出）
    opencode = { title = " OpenCode Chat ", paste_wrap = true, interrupt_key = "esc", new_cmd = "/new" },
    qodercli = { title = " Qoder CLI Chat ", paste_wrap = true },
    crush = { title = " Crush Chat " },
    -- omp: Esc interrupts the running agent; Ctrl+C only clears the editor
    -- (double Ctrl+C shuts omp down), so never send ctrl+c there.
    omp = { title = " Oh My Pi Chat ", interrupt_key = "esc" },
    pi = { title = " Pi Chat " },
    codex = { title = " Codex CLI Chat ", paste_wrap = true, new_cmd = "/new" },
    hermes = { title = " Hermes CLI Chat ", cmd = "hermes --tui" },
  },

  -- 静态的项目级启动命令覆盖（运行期设 vim.g.ai_tool_cmd = { codex = "..." } 依旧生效，
  -- 两者同时存在时 vim.g 优先，与原配置一致）
  tool_cmds = {},

  -- herdr 分屏参数
  split = { direction = "right", ratio = 0.55 },

  -- prompt 历史文件（按 cwd 分键；保持与原配置相同路径，历史可共用）
  history_file = "/tmp/cc_prompt_history.json",

  -- prompt 输入弹窗尺寸
  chat_size = { width = 85, height = 35 },

  icons = {
    folder = "",
    collapse_marks = { "", "" },
  },

  -- codex provider/model 切换（<leader>hm）
  codex = {
    home = "~/.codex",
    -- provider -> model 预设；provider 键需与 ~/.codex/config.toml 的
    -- [model_providers.<键>] 一致（openai 是内置默认 provider，无需在 toml 中声明）
    model_presets = {
      openai = { "gpt-6-astra", "gpt-5.6-sol" },
      ZAI = { "glm-5.3" },
      ["x-api"] = { "qwen3.8-max" },
    },
  },

  -- agentic 第三方插件适配：探测到 runtimepath 中存在 agentic 时自动注册后端；
  -- 不想自动注册可置 false，或用 register_tool() 挂自定义后端
  agentic = true,

  -- 用户命令名（置 false 关闭对应命令；:AIToggle 供 worktree_hook.sh 等外部脚本调用）
  commands = {
    toggle = "AIToggle",
    switch = "AISwitch",
  },

  -- 快捷键：默认【不绑定任何快捷键】，由用户显式传入才注册。每项独立配置完整
  -- lhs，可任意混用前缀（如 toggle 用 <leader>ox、input 用 <leader>he）。值支持：
  --   string  完整 lhs，如 "<leader>ho"（mode 用该功能的默认值）
  --   table   { "<leader>ai", mode = { "n", "i" }, desc = "自定义描述" }
  --   false   显式关闭（与不传等价）
  -- 不想走本配置项的，也可以不传 keys，直接用 API 自行 vim.keymap.set（见 README）
  keys = {
    -- toggle 的默认 mode 为 n；input 为 n + x（x 预填选区上下文）；
    -- switch 为 n；其余均为 n + x
    -- toggle = "<leader>ho",
    -- input = "<leader>he",
    -- interrupt = "<leader>hx",
    -- new_session = "<leader>hc",
    -- history = "<leader>hh",
    -- switch = "<leader>ht",
    -- read_buffer = "<leader>hr",
    -- add_buffer = "<leader>ha",
    -- select_session = "<leader>hs",
    -- switch_provider = "<leader>hy",
    -- codex_model = "<leader>hm",
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
---@return string|nil cmd 启动命令覆盖（vim.g.ai_tool_cmd 优先于 tool_cmds）
function M.tool_cmd(name)
  local overrides = vim.g.ai_tool_cmd
  if type(overrides) == "table" and overrides[name] then
    return overrides[name]
  end
  return M.options.tool_cmds[name]
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
