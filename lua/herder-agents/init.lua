-- herder-agents.nvim
--
-- 从本地 LazyVim 配置（lua/config/keymap_ai_tool.lua + lua/ai_tools/）抽象出的
-- AI 工具操作集：在 Herdr pane 中驱动 CLI 编码 agent（opencode / codex / qodercli /
-- crush / omp / pi / hermes...），并支持通过 register_tool() 接入非 herdr 后端（如 agentic）。
--
-- 默认快捷键（keys 配置项逐个可改，支持任意前缀混用，单项置 false 关闭）：
--   <leader>ho 打开/关闭工具 pane（已存在时切换 zoom）
--   <leader>he prompt 输入弹窗（visual 模式预填选区上下文）
--   <leader>hx 中断    <leader>hc 新会话    <leader>hh prompt 历史    <leader>ht 切换工具
--   <leader>hr/<leader>ha 当前缓冲区加入只读/可编辑上下文（非 herdr 后端）
--   <leader>hs 恢复会话 / <leader>hy 切换 provider（agentic 后端）
--   <leader>hm 切换 codex 的 provider/model
--
-- 命令：:AIToggle [tool]（<leader>ho 的命令版，供 worktree_hook.sh 等外部脚本调用）
--       :AISwitch [tool]（无参数时循环切换）
local M = {}

local config = require("herder-agents.config")
local tools = require("herder-agents.tools")

-- 前向声明（定义见文件后方，setup 引用）
local register_agentic
local setup_commands
local setup_keymaps

---@param opts table|nil 见 herder-agents.config
function M.setup(opts)
  config.setup(opts)

  if config.options.autoread then
    vim.o.autoread = true -- CLI 工具在外部 pane 改文件，buffer 自动重载
  end
  vim.g.ai_tool = vim.g.ai_tool or config.options.default_tool

  require("herder-agents.ui.common").setup_highlights()
  tools.register_herdr_tools()
  register_agentic()
  setup_commands()
  setup_keymaps()
end

-- ---------------------------------------------------------------------------
-- agentic 第三方插件适配：探测 runtimepath 中存在 agentic 模块时才注册，
-- 避免切换到不可用的工具；安装后自动恢复行为
-- ---------------------------------------------------------------------------

local dim_agentic_prompt_float -- 前向声明，agentic.input 引用

local function has_agentic()
  return #vim.api.nvim_get_runtime_file("lua/agentic/init.lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/agentic.lua", false) > 0
end

register_agentic = function()
  if not config.options.agentic or not has_agentic() then
    return
  end
  tools.register_tool("agentic", {
    toggle = function()
      require("agentic").toggle()
    end,
    input = function()
      require("agentic").open_prompt_float({ focus_prompt = true })
      vim.schedule(dim_agentic_prompt_float)
    end,
    history = function()
      require("agentic").open_prompt_history()
    end,
    interrupt = function()
      require("agentic").stop_generation()
    end,
    new = function()
      require("agentic").new_session()
    end,
    select_session = function()
      require("agentic").restore_session()
    end,
    switch_provider = function()
      require("agentic").switch_provider()
    end,
    read_buffer = function()
      require("agentic").add_files_to_context({ files = { vim.fn.expand("%:p") }, focus_prompt = false })
    end,
    add_buffer = function()
      require("agentic").add_file({ focus_prompt = false })
    end,
  })
end

-- agentic 的 prompt float 是独立实现，没有遮罩；
-- 复用通用的 common.dim，并把遮罩生命周期绑到 float 窗口关闭上
dim_agentic_prompt_float = function()
  local ok, SessionRegistry = pcall(require, "agentic.session_registry")
  if not ok then
    return
  end
  SessionRegistry.get_session_for_tab_page(nil, function(session)
    local prompt_float = session.widget and session.widget.prompt_float
    local winid = prompt_float and prompt_float:get_input_winid()
    if not winid then
      return
    end
    local close_dim = require("herder-agents.ui.common").dim(prompt_float.buf_nrs.input)
    -- input buffer 与主 widget 共享，buffer 事件可能不触发，改绑窗口关闭
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        close_dim()
      end,
    })
  end)
end

-- ---------------------------------------------------------------------------
-- 命令
-- ---------------------------------------------------------------------------

setup_commands = function()
  local cmds = config.options.commands

  if cmds.toggle then
    vim.api.nvim_create_user_command(cmds.toggle, function(opts)
      M.toggle(opts.args ~= "" and opts.args or nil)
    end, {
      nargs = "?",
      complete = function()
        return tools.names()
      end,
      desc = "Toggle AI tool (same as " .. config.key_hint("toggle", "<leader>ho") .. ")",
    })
  end

  if cmds.switch then
    vim.api.nvim_create_user_command(cmds.switch, function(opts)
      if opts.args ~= "" then
        tools.set(opts.args)
      else
        local names = tools.names()
        local current_index = vim.fn.index(names, tools.current_name())
        tools.set(names[(current_index + 1) % #names + 1])
      end
    end, {
      nargs = "?",
      complete = function()
        return tools.names()
      end,
      desc = "Switch AI tool",
    })
  end
end

-- ---------------------------------------------------------------------------
-- 快捷键
-- ---------------------------------------------------------------------------

setup_keymaps = function()
  local keys = config.options.keys

  -- 解析 keys[action]：返回 lhs, modes, desc_override
  local function resolve(action, default_modes)
    local spec = keys[action]
    if not spec then
      return nil, nil, nil
    end
    if type(spec) == "table" then
      return spec[1], spec.mode or default_modes, spec.desc
    end
    return spec, default_modes, nil
  end

  local function map(action, default_modes, rhs, desc)
    local lhs, modes, desc_override = resolve(action, default_modes)
    if not lhs then
      return
    end
    vim.keymap.set(modes, lhs, rhs, { desc = desc_override or desc })
  end

  map("toggle", { "n" }, function()
    M.toggle()
  end, "Toggle AI")

  -- input：n 与 x 的 rhs 不同（x 预填选区上下文），按 mode 拆开注册
  do
    local lhs, modes, desc_override = resolve("input", { "n", "x" })
    if lhs then
      local plain_modes, visual_modes = {}, {}
      for _, m in ipairs(modes) do
        if m == "x" or m == "v" then
          table.insert(visual_modes, m)
        else
          table.insert(plain_modes, m)
        end
      end
      local desc = desc_override or "AI Chat (prompt)"
      if #plain_modes > 0 then
        vim.keymap.set(plain_modes, lhs, function()
          M.input()
        end, { desc = desc })
      end
      -- 可视模式：把选区格式化为 @path (lines a-b) + fence 上下文，预填进草稿
      if #visual_modes > 0 then
        vim.keymap.set(visual_modes, lhs, function()
          M.input(require("herder-agents.context").selection())
        end, { desc = desc })
      end
    end
  end

  map("interrupt", { "n", "x" }, function()
    M.interrupt()
  end, "AI interrupt session")

  map("new_session", { "n", "x" }, function()
    M.new_session()
  end, "AI new session")

  map("history", { "n", "x" }, function()
    M.history()
  end, "AI Chat History")

  map("switch", { "n" }, function()
    M.switch_tool()
  end, "Switch AI tool")

  map("read_buffer", { "n", "x" }, function()
    local backend = tools.backend()
    if backend and backend.read_buffer then
      backend.read_buffer()
    end
  end, "AI read current buffer")

  map("add_buffer", { "n", "x" }, function()
    local backend = tools.backend()
    if backend and backend.add_buffer then
      backend.add_buffer()
    end
  end, "AI add current buffer")

  map("select_session", { "n", "x" }, function()
    local backend = tools.backend()
    if backend and backend.select_session then
      backend.select_session()
    end
  end, "AI select session")

  map("switch_provider", { "n", "x" }, function()
    local backend = tools.backend()
    if backend and backend.switch_provider then
      backend.switch_provider()
    end
  end, "AI cycle agent")

  -- codex 专用：记录当前会话 → 选 provider/model → /quit 退出后
  -- 用 codex resume <session> -m <model> -c model_provider=<provider> 重启
  map("codex_model", { "n", "x" }, function()
    M.switch_codex_model()
  end, "AI switch codex model")
end

-- ---------------------------------------------------------------------------
-- 公开 API
-- ---------------------------------------------------------------------------

---@param tool string|nil 指定工具（如命令参数），缺省用当前工具
function M.toggle(tool)
  if tool and not tools.set(tool) then
    return
  end
  tools.backend().toggle()
end

---@param content string|nil 预填草稿的内容（如选区上下文）
function M.input(content)
  tools.backend().input(content)
end

function M.interrupt()
  tools.backend().interrupt()
end

function M.new_session()
  tools.backend().new()
end

function M.history()
  tools.backend().history()
end

-- 选择器切换工具（fzf-lua 可用时用 fzf，否则 vim.ui.select）
function M.switch_tool()
  local names = tools.names()
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(names, {
      prompt = "AI Tool> ",
      winopts = {
        width = 0.4,
        height = 0.35,
        row = 0.5,
        col = 0.5,
        border = "rounded",
      },
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            tools.set(selected[1])
          end
        end,
      },
    })
    return
  end
  vim.ui.select(names, { prompt = "AI Tool> " }, function(choice)
    if choice then
      tools.set(choice)
    end
  end)
end

function M.select_session()
  local backend = tools.backend()
  if backend and backend.select_session then
    backend.select_session()
  end
end

function M.switch_provider()
  local backend = tools.backend()
  if backend and backend.switch_provider then
    backend.switch_provider()
  end
end

function M.switch_codex_model()
  if tools.current_name() ~= "codex" then
    require("herder-agents.utils").warn("Switch model 仅支持 codex（当前: " .. tools.current_name() .. "）")
    return
  end
  require("herder-agents.codex_model").switch()
end

M.register_tool = tools.register_tool
M.api = tools.api

-- 不经输入框，直接向指定工具的 herdr pane 发送 prompt 并回车提交
--（fzf-lua 诊断修复等外部调用方使用）
function M.send_prompt(name, text)
  return require("herder-agents.ui.chat").send_tool_prompt(name, text)
end

-- prompt 文件附件的会话（fzf-lua ctrl-h 等外部调用方使用）
function M.current_session()
  return require("herder-agents.sessions").current_session()
end

return M
