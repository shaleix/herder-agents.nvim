-- herder-agents.nvim 冒烟测试（headless）
-- 运行：nvim --headless -u NONE --cmd "set rtp^=<repo>" -l test/smoke.lua
vim.g.mapleader = " "

local plugin = require("herder-agents")

local function check(cond, msg)
  if not cond then
    error("FAIL: " .. msg, 2)
  end
  print("ok - " .. msg)
end

local function has_map(lhs, mode)
  return vim.fn.maparg(lhs, mode) ~= ""
end

-- 默认 keys 为空：setup 后不绑定任何快捷键
plugin.setup({
  tools = { mycli = { title = " My CLI Chat " } },
})
check(not has_map(" ho", "n"), "默认不绑定 <leader>ho")
check(not has_map(" he", "n"), "默认不绑定 <leader>he")
check(not has_map(" hm", "n"), "默认不绑定 <leader>hm")

-- 显式传入 keys 才注册
plugin.setup({
  tools = { mycli = { title = " My CLI Chat " } },
  keys = {
    toggle = "<leader>ho",
    input = "<leader>he",
    interrupt = "<leader>hx",
    new_session = "<leader>hc",
    history = "<leader>hh",
    switch = "<leader>ht",
    read_buffer = "<leader>hr",
    add_buffer = "<leader>ha",
    codex_model = "<leader>hm",
  },
})

check(has_map(" ho", "n"), "<leader>ho (n) 已注册")
check(has_map(" he", "n"), "<leader>he (n) 已注册")
check(has_map(" he", "x"), "<leader>he (x) 已注册")
check(has_map(" hx", "n"), "<leader>hx 已注册")
check(has_map(" hc", "n"), "<leader>hc 已注册")
check(has_map(" hh", "n"), "<leader>hh 已注册")
check(has_map(" ht", "n"), "<leader>ht 已注册")
check(has_map(" hr", "n"), "<leader>hr 已注册")
check(has_map(" ha", "n"), "<leader>ha 已注册")
check(has_map(" hm", "n"), "<leader>hm 已注册")
check(not has_map(" hs", "n"), "未传入的动作不注册")
check(plugin.register_tool == nil, "外部后端注册机制已移除（herdr-only）")

-- commands
local cmds = vim.api.nvim_get_commands({})
check(cmds.AIToggle ~= nil, ":AIToggle 已创建")
check(cmds.AISwitch ~= nil, ":AISwitch 已创建")

-- 状态
check(vim.g.ai_tool == "opencode", "vim.g.ai_tool 默认 opencode")
check(vim.o.autoread, "autoread 已开启")

-- 工具注册表
local tools = require("herder-agents.tools")
local names = tools.names()
check(names[1] == "opencode", "切换器首项为 opencode")
check(vim.tbl_contains(names, "mycli"), "setup 新增工具 mycli 已注册")
check(vim.tbl_contains(names, "hermes"), "默认工具 hermes 已注册")

-- 工具切换
check(tools.set("codex"), "set codex 成功")
check(vim.g.ai_tool == "codex", "vim.g.ai_tool 已切换")
check(tools.backend() ~= nil, "backend() 返回 codex 后端")
check(not tools.set("nonexistent"), "set 未知工具返回 false")
check(tools.set("opencode"), "切回 opencode")

-- api / 会话文件
plugin.api.add_file("/tmp/herder-agents-smoke.lua")
local files = plugin.current_session():list_files()
check(#files.added == 1, "api.add_file 进入会话附件")
plugin.current_session():drop_files(files.added)
files = plugin.current_session():list_files()
check(#files.added == 0, "drop_files 清空会话附件")

-- 手动绑定所需的 API 均存在
for _, fn in ipairs({
  "toggle",
  "input",
  "interrupt",
  "new_session",
  "history",
  "switch_tool",
  "read_buffer",
  "add_buffer",
  "switch_codex_model",
}) do
  check(type(plugin[fn]) == "function", "API ." .. fn .. "() 存在")
end

-- hr / ha：当前缓冲区加入附件会话
vim.api.nvim_buf_set_name(0, "/tmp/herder-agents-smoke2.lua")
plugin.add_buffer()
files = plugin.current_session():list_files()
check(#files.added == 1, "add_buffer 把当前缓冲区加入可编辑附件")
plugin.current_session():clear_files()
plugin.read_buffer()
files = plugin.current_session():list_files()
check(#files.readonly == 1, "read_buffer 把当前缓冲区加入只读附件")
plugin.current_session():clear_files()

-- send_prompt 对未注册工具
check(plugin.send_prompt("nonexistent", "hi") == false, "send_prompt 未知工具返回 false")

-- 无 Herdr 环境时 toggle 只报错不崩溃
plugin.toggle()
check(true, "无 HERDR_ENV 时 toggle 不抛异常")

-- context.selection 无选区时返回 nil
check(require("herder-agents.context").selection() == nil, "selection() 无选区返回 nil")

-- 项目级命令覆盖：vim.g 优先
vim.g.ai_tool_cmd = { codex = 'codex -m "gpt-6-astra"' }
check(require("herder-agents.config").tool_cmd("codex") == 'codex -m "gpt-6-astra"', "tool_cmd vim.g 覆盖")
check(require("herder-agents.config").key_hint("toggle", "?") == "<leader>ho", "key_hint 反映已绑定键")
check(require("herder-agents.config").key_hint("nonexistent", "?") == "?", "key_hint 未绑定返回 fallback")

-- 自定义完整 lhs（不同前缀混用）与 table spec（mode 覆盖）
plugin.setup({
  keys = {
    toggle = "<leader>ox",
    input = "<leader>ie",
    interrupt = { "<leader>xx", mode = { "n" } },
  },
})
check(has_map(" ox", "n"), "自定义 toggle=<leader>ox 生效")
check(has_map(" ie", "n"), "自定义 input=<leader>ie (n) 生效")
check(has_map(" ie", "x"), "自定义 input=<leader>ie (x) 生效")
check(has_map(" xx", "n"), "table spec interrupt (n) 生效")
check(not has_map(" xx", "x"), "spec mode 覆盖后 interrupt 不注册 x")
check(require("herder-agents.config").key_hint("toggle", "?") == "<leader>ox", "key_hint 反映自定义绑定")

print("ALL PASSED")
