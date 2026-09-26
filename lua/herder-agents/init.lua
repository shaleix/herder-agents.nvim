-- herder-agents.nvim
--
-- 在 Neovim 中驱动跑在 Herdr pane 里的 CLI 编码 agent
-- （opencode / codex / qodercli / crush / omp / pi / hermes ...），
-- 提供统一的 prompt 输入弹窗、历史、中断、新会话等操作。
-- 工具一律以 CLI 命令形式在 herdr 分屏 pane 中启动，无编辑器内后端集成。
--
-- 快捷键默认【不绑定】，两种绑定方式（见 README）：
--   1. setup({ keys = { toggle = "<leader>ho", input = "<leader>he", ... } })
--   2. 不传 keys，直接 vim.keymap.set 调 API（M.toggle() / M.input() / ...）
--
-- 命令：:AIToggle [tool]（toggle 的命令版，供 worktree_hook.sh 等外部脚本调用）
--       :AISwitch [tool]（无参数时循环切换）
local M = {}

local config = require("herder-agents.config")
local tools = require("herder-agents.tools")

-- 前向声明（定义见文件后方，setup 引用）
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
  setup_commands()
  setup_keymaps()
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
    M.read_buffer()
  end, "AI read current buffer")

  map("add_buffer", { "n", "x" }, function()
    M.add_buffer()
  end, "AI add current buffer")

  -- 备注：普通模式取光标行，可视模式取选区行范围
  map("note", { "n", "x" }, function()
    M.add_note()
  end, "AI add note at cursor/selection")

  -- Notes 审阅/提交弹窗
  map("notes_view", { "n", "x" }, function()
    M.notes_view()
  end, "AI notes view (review & send)")

  -- 切换 agent 模式（按工具 mode_switch 配置经 herdr 发送指令）
  map("switch_mode", { "n", "x" }, function()
    M.switch_mode()
  end, "AI switch agent mode")

  -- 模型切换：codex 走专用 provider/model 重启流程（记录会话 → 选择 → /quit →
  -- codex resume <session> -m <model>）；其他工具按 model_switch 配置经 herdr 发送
  map("codex_model", { "n", "x" }, function()
    M.switch_model()
  end, "AI switch model")
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

-- 切换当前工具的 agent 模式（opencode: Tab 循环 build/plan；codex: /approvals；
-- 其余工具在 config.tools.<name>.mode_switch 里自定义 keys/cmd）
function M.switch_mode()
  local backend = tools.backend()
  if backend and backend.switch_mode then
    backend.switch_mode()
  end
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

-- 切换模型（<leader>hm 统一入口）：
-- codex → 专用 provider/model 选择 + 会话 resume 重启流程；
-- 其他工具 → 按 tools.<name>.model_switch 经 herdr 发送 keys/cmd
--（opencode v2 默认 ctrl+x m 打开模型选择对话框，pane 内选中即会话内实时生效，无需重启）
function M.switch_model()
  if tools.current_name() == "codex" then
    require("herder-agents.codex_model").switch()
    return
  end
  local backend = tools.backend()
  if backend and backend.switch_model then
    backend.switch_model()
  end
end

-- 兼容旧 API：等价于 switch_model()（不再仅限 codex）
function M.switch_codex_model()
  M.switch_model()
end

-- ---------------------------------------------------------------------------
-- 文件附件（<leader>hr / <leader>ha）
-- 与 prompt 弹窗顶部文件树、fzf-lua ctrl-h 共用同一会话；
-- 提交时未在草稿中 @提及 的附件以 "Relate file:" 块附加
-- ---------------------------------------------------------------------------

M.api = {}

function M.api.add_current_buffer()
  if vim.bo.buftype == "" then
    local buffer_path = vim.fn.expand("%:p")
    require("herder-agents.sessions").current_session():add_files({ buffer_path })
  end
end

function M.api.read_current_buffer()
  if vim.bo.buftype == "" then
    local buffer_path = vim.fn.expand("%:p")
    require("herder-agents.sessions").current_session():read_files({ buffer_path })
  end
end

function M.api.add_file(path)
  require("herder-agents.sessions").current_session():add_files({ path })
  vim.notify("Added file: " .. path, vim.log.levels.INFO)
end

function M.api.read_file(path)
  require("herder-agents.sessions").current_session():read_files({ path })
  vim.notify("Read file: " .. path, vim.log.levels.INFO)
end

-- 以编程方式添加备注（供外部脚本 / 测试使用）
function M.api.add_note(path, start_line, end_line, text)
  return require("herder-agents.notes").add(path, start_line, end_line, text)
end

function M.read_buffer()
  M.api.read_current_buffer()
end

function M.add_buffer()
  M.api.add_current_buffer()
end

-- 在当前缓冲区添加备注（普通模式=光标行，可视模式=选区行范围）：
-- 弹出输入框录入文本，保存进会话备注，并在源缓冲区用 extmark 标记；
-- 备注会显示在 Chat 弹窗 "Relate file" 下方的 "Notes" 区，勾选后随 prompt 发送
function M.add_note()
  if vim.bo.buftype ~= "" then
    require("herder-agents.utils").warn("Cannot annotate a special buffer")
    return
  end
  local range = require("herder-agents.context").note_range()
  if not range then
    require("herder-agents.utils").warn("No file to annotate")
    return
  end
  require("herder-agents.ui.chat").add_note(range)
end

-- Notes 审阅/提交弹窗（独立于 Chat）：默认全选，可勾选/删除，
-- 底部 Extra Prompt 随勾选备注一同发送；
-- <CR> 直接发送（带回车），<C-a> 仅追加到 agent 输入框（不带回车）
function M.notes_view()
  require("herder-agents.ui.notes_view").show()
end

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
