-- herder-agents.nvim 冒烟测试（headless）
-- 运行：nvim --headless -u NONE --cmd "set rtp^=<repo>" -l test/smoke.lua
vim.g.mapleader = " "

local plugin = require("herder-agents")
plugin.setup({
  tools = { mycli = { title = " My CLI Chat " } },
  keys = { select_session = false },
})

local function check(cond, msg)
  if not cond then
    error("FAIL: " .. msg, 2)
  end
  print("ok - " .. msg)
end

local function has_map(lhs, mode)
  return vim.fn.maparg(lhs, mode) ~= ""
end

-- keymaps（leader = 空格，前缀 <leader>h）
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
check(not has_map(" hs", "n"), "keys.select_session=false 时 <leader>hs 不注册")

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
check(not tools.set("nonexistent"), "set 未知工具返回 false")

-- 外部后端注册
local toggled = false
plugin.register_tool("fake", {
  toggle = function()
    toggled = true
  end,
})
tools.set("fake")
plugin.toggle()
check(toggled, "外部后端 register_tool 后 toggle 生效")
check(tools.set("opencode"), "切回 opencode")

-- api / 会话文件
plugin.api.add_file("/tmp/herder-agents-smoke.lua")
local files = plugin.current_session():list_files()
check(#files.added == 1, "api.add_file 进入会话附件")
plugin.current_session():drop_files(files.added)
files = plugin.current_session():list_files()
check(#files.added == 0, "drop_files 清空会话附件")

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

print("ALL PASSED")
