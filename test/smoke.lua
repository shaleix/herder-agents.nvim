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
    note = "<leader>hn",
    line_prompt = "<leader>hp",
    notes_view = "<leader>hN",
    switch_mode = "<leader>hM",
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
check(has_map(" hn", "n"), "<leader>hn (n) 已注册")
check(has_map(" hn", "x"), "<leader>hn (x) 已注册")
check(has_map(" hp", "n"), "<leader>hp (n) 已注册")
check(has_map(" hp", "x"), "<leader>hp (x) 已注册")
check(has_map(" hN", "n"), "<leader>hN (n) 已注册")
check(has_map(" hM", "n"), "<leader>hM (n) 已注册")
check(has_map(" hM", "x"), "<leader>hM (x) 已注册")
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
check(require("herder-agents.config").options.switch_replace == true, "switch_replace 默认开启")

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
  "add_note",
  "add_prompt",
  "notes_view",
  "switch_mode",
  "switch_model",
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

-- 备注（notes）：会话 store、勾选态、extmark、格式化、note_range
local notes = require("herder-agents.notes")
local context = require("herder-agents.context")
notes.clear()
vim.api.nvim_buf_set_name(0, "/tmp/herder-agents-notes.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d", "e", "f" })
local n1 = notes.add("/tmp/herder-agents-notes.lua", 2, 2, "first note")
local n2 = notes.add("/tmp/herder-agents-notes.lua", 4, 6, "second\nnote")
check(#notes.list() == 2, "notes.add 存入两条备注")
check(n1.checked == true, "新建备注默认勾选")
check(#notes.checked() == 2, "两条备注默认都勾选")
check(n1.extmark_id ~= nil, "备注在已加载缓冲区渲染 extmark")
notes.toggle(n1.id)
check(n1.checked == false, "toggle 取消勾选")
check(#notes.checked() == 1, "取消勾选后只剩一条勾选")
local ordered = notes.list()
check(ordered[1].id == n1.id and ordered[2].id == n2.id, "list() 按起始行排序")
-- notes_block：只含勾选备注，多行压成单行，含位置
local block = context.notes_block(notes.checked())
check(
  block ~= nil and block:match("^Please address these code review comments:") ~= nil,
  "notes_block 以指令式标题开头"
)
check(block:find("(lines 4-6)", 1, true) ~= nil, "notes_block 含多行位置")
check(block:find("second note", 1, true) ~= nil, "notes_block 多行内容压成单行")
check(block:find("first note", 1, true) == nil, "notes_block 不含未勾选备注")
notes.sync_positions()
check(n2.start_line == 4 and n2.end_line == 6, "sync_positions 无编辑时保持行号")
notes.check_all()
check(n1.checked == true and #notes.checked() == 2, "check_all 全部勾选")
notes.remove(n1.id)
check(#notes.list() == 1, "remove 后剩一条备注")
notes.clear()
check(#notes.list() == 0, "clear 清空全部备注")
check(context.notes_block(notes.checked()) == nil, "notes_block 空列表返回 nil")
-- note_range：普通模式取光标单行
vim.api.nvim_win_set_cursor(0, { 3, 0 })
local range = context.note_range()
check(range ~= nil and range.start_line == 3 and range.end_line == 3, "note_range 普通模式取光标单行")
check(range.path == "/tmp/herder-agents-notes.lua", "note_range 返回缓冲区路径")
-- api.add_note 编程入口
local n3 = plugin.api.add_note("/tmp/herder-agents-notes.lua", 1, 1, "via api")
check(n3 ~= nil and #notes.list() == 1, "api.add_note 存入备注")
notes.clear()

-- extmark 跟随编辑：上方插入一行后 sync_positions 应读回移动后的新行号
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d", "e", "f" })
local nt = notes.add("/tmp/herder-agents-notes.lua", 3, 4, "track me")
check(nt.start_line == 3 and nt.end_line == 4, "备注初始行号 3-4")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "NEW" }) -- 顶部插入一行
notes.sync_positions()
check(nt.start_line == 4 and nt.end_line == 5, "上方插入行后 extmark 跟随到 4-5")
notes.clear()

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

-- ---------------------------------------------------------------------------
-- delivery / context 上限 / 事件（借鉴 codex.nvim 的机制）
-- ---------------------------------------------------------------------------
local delivery = require("herder-agents.delivery")
local utils = require("herder-agents.utils")

-- context 上限：超限拒绝而非截断
local ctx_cfg = require("herder-agents.config").options.context
check(ctx_cfg.max_lines == 500 and ctx_cfg.max_bytes == 65536, "context 上限默认 500 行 / 64KB")
local context2 = require("herder-agents.context")
local big_lines = {}
for i = 1, 501 do
  big_lines[i] = "line" .. i
end
check(context2._check_limits(big_lines, table.concat(big_lines, "\n")) ~= nil, "选区超行数上限被拒绝")
check(context2._check_limits({ "a" }, string.rep("x", 65537)) ~= nil, "选区超字节上限被拒绝")
check(context2._check_limits({ "a", "b" }, "ab") == nil, "上限内选区通过")

-- 草稿绑定校验：pane 被替换时拒绝
check(delivery.check_binding("codex", "pane-1", { pane_id = "pane-1" }), "绑定一致时放行")
check(not delivery.check_binding("codex", "pane-1", { pane_id = "pane-2" }), "pane 被替换时拒绝")
check(delivery.check_binding("codex", nil, { pane_id = "pane-2" }), "打开时无 pane（nil 绑定）放行")
check(delivery.check_binding("codex", "pane-1", nil), "提交时无 pane 参数放行（调用方另行报错）")

-- 空队列丢弃 / 计数
delivery._reset()
check(delivery.pending_count() == 0, "初始无排队 prompt")
check(delivery.drop_all() == 0, "drop_all 空队列返回 0")

-- pane 查询：不存在的 pane 不崩溃（无 herdr 守护进程时同样返回 nil/false）
local running = delivery.pane_agent_running("definitely-not-a-pane")
check(running == nil or running == false, "pane_agent_running 查询失败返回 nil/false 不抛异常")

-- User 事件（payload 在 event.data）
local captured = {}
vim.api.nvim_create_autocmd("User", {
  pattern = { "AIPromptSent", "AIPromptQueued", "AIDeliveryFailed" },
  callback = function(event)
    table.insert(captured, { pattern = event.match, data = event.data })
  end,
})
utils.emit("AIPromptSent", { tool = "codex", pane_id = "p1", submitted = true, queued = false })
check(#captured == 1 and captured[1].pattern == "AIPromptSent", "AIPromptSent 事件已发出")
check(captured[1].data.tool == "codex" and captured[1].data.queued == false, "事件 payload 在 event.data")

-- :AIDropQueue 命令存在
local cmds2 = vim.api.nvim_get_commands({})
check(cmds2.AIDropQueue ~= nil, ":AIDropQueue 已创建")

-- delivery 关闭时（enabled=false）deliver 直接同步投递且以退出码判定：
-- 本环境无 herdr daemon，send-text 必失败 → 返回 false 并发 AIDeliveryFailed
require("herder-agents.config").options.delivery.enabled = false
local done = false
local ok_delivery = delivery.deliver("definitely-not-a-pane", "codex", "hello", {
  submit_key = "enter",
  on_done = function(ok, queued)
    done = true
    check(ok == false and queued == false, "投递失败 on_done(false,false)")
  end,
})
check(ok_delivery == false, "herdr 不可用时 deliver 返回 false（不再假成功）")
check(done, "on_done 同步回调已执行")
check(#captured >= 2 and captured[#captured].pattern == "AIDeliveryFailed", "投递失败发出 AIDeliveryFailed")
require("herder-agents.config").options.delivery.enabled = true
delivery._reset()

-- enabled 排队路径：无 herdr daemon 时 ready 探测失败 → 入队返回 true，
-- 实际投递由 timer 链异步驱动（headless 下不等待触发）
local ok_queue = delivery.deliver("definitely-not-a-pane", "codex", "hello", { submit_key = "enter" })
check(ok_queue == true, "agent 未就绪时 deliver 入队并返回 true")
check(delivery.pending_count() == 1, "入队后 pending_count 为 1")
check(delivery.drop_all() == 1, "drop_all 丢弃排队项并返回 1")
check(delivery.pending_count() == 0, "丢弃后 pending_count 归零")
delivery._reset()

-- ---------------------------------------------------------------------------
-- agent 集成通道（herdr agent prompt / agent wait，用法借鉴 herdr-nvim）：
-- 通过 utils.set_exec / set_exec_async 注入假执行器，无 herdr 也能验证
-- 通道判定与提交路径选择
-- ---------------------------------------------------------------------------
local config_mod = require("herder-agents.config")

local fake_agents = {} -- pane_id -> agent_status
local fake_ws = "w-test" -- 假 agent 的 workspace_id
local argv_log = {}
utils.set_exec(function(argv)
  table.insert(argv_log, argv)
  if argv[2] == "agent" and argv[3] == "list" then
    local agents = {}
    for pane_id, status in pairs(fake_agents) do
      table.insert(agents, {
        pane_id = pane_id,
        agent = "codex",
        agent_status = status,
        workspace_id = fake_ws,
        cwd = "/tmp",
      })
    end
    return { code = 0, stdout = vim.json.encode({ result = { agents = agents } }) }
  end
  if argv[2] == "pane" and argv[3] == "process-info" then
    return {
      code = 0,
      stdout = vim.json.encode({
        result = {
          process_info = {
            shell_pid = 1,
            foreground_processes = { { pid = 2 } },
            foreground_process_group_id = 2,
          },
        },
      }),
    }
  end
  return { code = 0, stdout = "" }
end)
utils.set_exec_async(function(argv, on_done)
  table.insert(argv_log, argv)
  -- 模拟服务端：agent wait 成功后该 pane 变为 idle
  if argv[2] == "agent" and argv[3] == "wait" then
    fake_agents[argv[4]] = "idle"
  end
  on_done({ code = 0, stdout = "", stderr = "" })
end)

local function argv_contains(pred)
  for _, argv in ipairs(argv_log) do
    if pred(argv) then
      return true
    end
  end
  return false
end

-- 1) 已注册 idle 的 agent + 回车提交 → agent prompt 原文直传，不走 send-text
fake_agents = { ["p-agent"] = "idle" }
argv_log = {}
local agent_done = nil
local ok_agent = delivery.deliver("p-agent", "codex", "hello\nmulti line", {
  submit_key = "enter",
  on_done = function(ok)
    agent_done = ok
  end,
})
check(ok_agent == true, "agent 通道 deliver 受理")
check(agent_done == true, "agent prompt on_done 成功")
check(
  argv_contains(function(argv)
    return argv[2] == "agent" and argv[3] == "prompt" and argv[4] == "p-agent" and argv[5] == "hello\nmulti line"
  end),
  "agent 通道用 agent prompt 提交（原文直传）"
)
check(not argv_contains(function(argv)
  return argv[3] == "send-text"
end), "agent 通道不再走 send-text（无 paste 编码）")

-- 2) 未注册 pane（自定义工具）→ 文本通道：send-text + enter + paste 编码
fake_agents = {}
argv_log = {}
local ok_text = delivery.deliver("p-plain", "mycli", "multi\nline", {
  submit_key = "enter",
  paste_wrap = true,
})
check(ok_text == true, "文本通道 deliver 成功")
local sent_text, sent_key = nil, nil
for _, argv in ipairs(argv_log) do
  if argv[3] == "send-text" then
    sent_text = argv[5]
  end
  if argv[3] == "send-keys" then
    sent_key = argv[5]
  end
end
check(sent_text ~= nil and sent_text:find("\27[200~", 1, true) ~= nil, "文本通道保留 bracketed paste 编码")
check(sent_key == "enter", "文本通道补提交键 enter")
check(not argv_contains(function(argv)
  return argv[3] == "prompt"
end), "未注册 pane 不走 agent prompt")

-- 3) tab 提交（codex /queue）即使已注册也走文本通道
fake_agents = { ["p-tab"] = "idle" }
argv_log = {}
delivery.deliver("p-tab", "codex", "/queue task", { submit_key = "tab", paste_wrap = true })
check(not argv_contains(function(argv)
  return argv[3] == "prompt"
end), "tab 提交（/queue）不走 agent prompt")
check(
  argv_contains(function(argv)
    return argv[3] == "send-keys" and argv[5] == "tab"
  end),
  "tab 提交走 send-keys tab"
)

-- 4) 注册但状态 unknown → 排队，经 agent wait（服务端等待）后 flush
delivery._reset()
fake_agents = { ["p-unknown"] = "unknown" }
argv_log = {}
local ok_q = delivery.deliver("p-unknown", "codex", "queued hello", { submit_key = "enter" })
check(ok_q == true and delivery.pending_count() == 1, "unknown 状态进入排队")
vim.wait(3000, function()
  return delivery.pending_count() == 0
end, 20)
check(delivery.pending_count() == 0, "agent wait 就绪后自动 flush")
check(
  argv_contains(function(argv)
    return argv[3] == "wait" and argv[4] == "p-unknown"
  end),
  "排队等待使用 herdr agent wait（服务端精确等待）"
)
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[4] == "p-unknown"
  end),
  "flush 后经 agent prompt 提交"
)

-- 5) agent_channel = false → 一律文本通道（escape hatch）
config_mod.options.delivery.agent_channel = false
fake_agents = { ["p-off"] = "idle" }
argv_log = {}
delivery.deliver("p-off", "codex", "hello", { submit_key = "enter" })
check(not argv_contains(function(argv)
  return argv[3] == "prompt"
end), "agent_channel=false 强制文本通道")
check(
  argv_contains(function(argv)
    return argv[3] == "send-text"
  end),
  "agent_channel=false 回退 send-text"
)
config_mod.options.delivery.agent_channel = true

-- 6) status 轮询用 agent list：状态变化发事件（含 cwd），unknown 不发
local status_mod = require("herder-agents.status")
status_mod._reset()
local saved_ws = vim.env.HERDR_WORKSPACE_ID
vim.env.HERDR_WORKSPACE_ID = "w-test"
local status_events = {}
vim.api.nvim_create_autocmd("User", {
  pattern = { "AIAgentWorking", "AIAgentIdle", "AIAgentBlocked" },
  callback = function(event)
    table.insert(status_events, { match = event.match, data = event.data })
  end,
})
fake_agents = { ["s1"] = "working", ["s2"] = "idle", ["s3"] = "unknown" }
status_mod._tick()
check(#status_events == 2, "agent list 轮询发出 idle/working 事件（unknown 不发）")
local saw_working, saw_cwd = false, false
for _, ev in ipairs(status_events) do
  if ev.match == "AIAgentWorking" and ev.data.pane_id == "s1" then
    saw_working = true
  end
  if ev.data.cwd == "/tmp" then
    saw_cwd = true
  end
end
check(saw_working, "AIAgentWorking 事件 payload 正确")
check(saw_cwd, "事件 payload 含 agent cwd")
status_mod._tick()
check(#status_events == 2, "状态未变不重复发事件")
fake_agents["s2"] = "working"
status_mod._tick()
check(#status_events == 3 and status_events[3].match == "AIAgentWorking", "状态变化发出新事件")
fake_agents = { ["s-other"] = "working" }
fake_ws = "w-other"
status_events = {}
status_mod._tick()
check(#status_events == 0, "其他 workspace 的 agent 被过滤")
fake_ws = "w-test"
if saved_ws then
  vim.env.HERDR_WORKSPACE_ID = saved_ws
else
  vim.env.HERDR_WORKSPACE_ID = nil
end
status_mod._reset()

-- 恢复真实执行器
utils.set_exec(nil)
utils.set_exec_async(nil)
delivery._reset()

print("ALL PASSED")
