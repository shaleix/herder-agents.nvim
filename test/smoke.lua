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
    model = "<leader>hm",
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

-- opencode 默认不配置 models：<leader>hm 走 model_switch 对话框兜底
local oc_models = require("herder-agents.config").options.tools.opencode.models
check(oc_models == nil, "opencode 默认不配置 models（走 model_switch 兜底）")

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

-- ---------------------------------------------------------------------------
-- 中断按键序列：opencode 两段式 Esc（第一次 Esc 只进入 "ESC again to interrupt"
-- 待确认态，第二次才真正中断），第二键经 defer 间隔发送；单键工具不受影响
-- ---------------------------------------------------------------------------
local chat_mod = require("herder-agents.ui.chat")
local fake_panes = {
  { label = "opencode", tab_id = "t1", pane_id = "p-oc" },
  { label = "omp", tab_id = "t1", pane_id = "p-omp" },
}
local send_keys_log = {}
utils.set_exec(function(argv)
  table.insert(argv_log, argv)
  if argv[2] == "pane" and argv[3] == "current" then
    return { code = 0, stdout = vim.json.encode({ result = { pane = { tab_id = "t1" } } }) }
  end
  if argv[2] == "pane" and argv[3] == "list" then
    return { code = 0, stdout = vim.json.encode({ result = { panes = fake_panes } }) }
  end
  if argv[2] == "pane" and argv[3] == "send-keys" then
    table.insert(send_keys_log, { pane_id = argv[4], key = argv[5] })
  end
  return { code = 0, stdout = "" }
end)
utils.set_exec_async(function(argv, on_done)
  on_done({ code = 0, stdout = "", stderr = "" })
end)

chat_mod.interrupt_tool("opencode")
check(#send_keys_log == 1 and send_keys_log[1].key == "esc", "opencode 中断立即发出第一个 esc")
local seq_done = vim.wait(2000, function()
  return #send_keys_log >= 2
end)
check(seq_done, "opencode 中断序列补发第二个 esc（defer 间隔发送）")
check(
  #send_keys_log == 2
    and send_keys_log[1].pane_id == "p-oc"
    and send_keys_log[2].pane_id == "p-oc"
    and send_keys_log[2].key == "esc",
  "两个 esc 均发往 opencode pane"
)

send_keys_log = {}
chat_mod.interrupt_tool("omp")
vim.wait(600, function()
  return false
end)
check(#send_keys_log == 1 and send_keys_log[1].key == "esc", "omp 单键中断不变（仍是一个 esc）")

-- ---------------------------------------------------------------------------
-- 终端模式复位（utils.reset_pane_terminal）：agent 退出后遗留 kitty keyboard /
-- SGR 鼠标上报等终端模式，输入行被编码后的按键/鼠标事件持续污染
-- （"5:1u9;5:1uopencode" → command not found）。复位序列只能由 pane 内 shell
-- 执行 printf 写 tty 输出侧关闭，且必须单次 send-text 原子送达（前导 \r
-- 无害提交已被污染的当前行，避免与涌入的鼠标事件交错粘连）
-- ---------------------------------------------------------------------------
local reset_argv = nil
utils.set_exec(function(argv)
  if argv[2] == "pane" and argv[3] == "send-text" then
    reset_argv = argv
  end
  return { code = 0, stdout = "" }
end)
check(utils.reset_pane_terminal("p-x") == true, "终端复位经 pane send-text 发送，以退出码判定")
check(
  reset_argv ~= nil
    and reset_argv[4] == "p-x"
    and reset_argv[5] == "\rprintf '\\e[<u\\e[<u\\e[?1000l\\e[?1002l\\e[?1003l\\e[?1006l\\e[?2004l\\e[?25h'\r",
  "复位载荷：前导 \\r + printf 关 kitty pop×2/鼠标/bracketed paste/恢复光标"
)
utils.set_exec(nil)

-- ---------------------------------------------------------------------------
-- 模型切换统一流程（model_restart）：两级 models 平铺单选 → 按工具配置应用 ——
-- opencode 默认 model_apply="api" 原地切换（api post session model）；
-- 重启路径（优雅退出 → model_resume 模板重启）仍可显式配置使用
-- ---------------------------------------------------------------------------
local model_restart = require("herder-agents.model_restart")

check(
  vim.deep_equal(
    model_restart._flatten_models({ openai = { "gpt-5.4" }, anthropic = { "opus", "sonnet" } }),
    { "anthropic/opus", "anthropic/sonnet", "openai/gpt-5.4" }
  ),
  "两级 models 平铺为排序的 provider/model 列表"
)
local sp, sm = model_restart._split_entry("zhipuai/glm-5.3#high")
check(sp == "zhipuai" and sm == "glm-5.3#high", "候选解析出 provider 与 model（#variant 留在 model 内）")
check(
  vim.deep_equal(
    model_restart._substitute(
      { "codex", "resume", "{session}", "-m", "'{model}'", "-c", "'model_provider=\"{provider}\"'" },
      { session = "ses_1", provider = "ZAI", model = "glm-5.3" }
    ),
    { "codex", "resume", "ses_1", "-m", "'glm-5.3'", "-c", "'model_provider=\"ZAI\"'" }
  ),
  "重启模板占位符替换（含 shell 引号参数）"
)

-- opencode 会话定位：标题精确匹配 pane 的 terminal_title，无匹配取最新
local oc_sessions = {
  { id = "ses_old", title = "旧会话", time = { updated = 1 } },
  { id = "ses_hit", title = "模型切换测试", time = { updated = 2 } },
}
local saved_exec = utils.exec
utils.set_exec(function(argv)
  if argv[1] == "opencode" and argv[2] == "api" then
    local dir = argv[5] and argv[5]:match("^directory=(.*)$") or argv[6] and argv[6]:match("^directory=(.*)$")
    local out = dir == "/home/ecs-user/workerspace" and oc_sessions or {}
    return { code = 0, stdout = vim.json.encode({ data = out }) }
  end
  return { code = 0, stdout = "" }
end)
local oc_pane = { cwd = "/home/ecs-user/workerspace", terminal_title_stripped = "OC | 模型切换测试" }
check(model_restart._opencode_session_id(oc_pane) == "ses_hit", "opencode 会话按标题精确匹配")
oc_pane.terminal_title_stripped = "OC | 不存在的标题"
check(model_restart._opencode_session_id(oc_pane) == "ses_hit", "标题无匹配时取最新会话")

-- 完整切换流程：默认 model_apply="api" 原地切换（api post，不退出不重启）；
-- 显式配置 model_resume 的工具仍走 选中 → /quit 退出 → pane run 按模板重启
local mr_log = {}
local mr_api_code = 0 -- opencode api post /model 的退出码（可注入失败场景）
local agent_up = true -- process-info：重启前 agent 在跑，pane run 后重新在跑
utils.set_exec(function(argv)
  table.insert(argv_log, argv)
  if argv[1] == "opencode" and argv[2] == "api" and argv[3] == "post" then
    table.insert(mr_log, "api:" .. table.concat(argv, ",", 4))
    return {
      code = mr_api_code,
      stdout = "",
      stderr = mr_api_code == 0 and "" or "unknown model",
    }
  end
  if argv[1] == "opencode" and argv[2] == "api" then
    local dir = argv[5] and argv[5]:match("^directory=(.*)$") or argv[6] and argv[6]:match("^directory=(.*)$")
    local out = dir == "/home/ecs-user/workerspace" and oc_sessions or {}
    return { code = 0, stdout = vim.json.encode({ data = out }) }
  end
  if argv[2] == "pane" and argv[3] == "current" then
    return { code = 0, stdout = vim.json.encode({ result = { pane = { tab_id = "t1" } } }) }
  end
  if argv[2] == "pane" and argv[3] == "list" then
    return {
      code = 0,
      stdout = vim.json.encode({
        result = {
          panes = {
            {
              label = "opencode",
              tab_id = "t1",
              pane_id = "p-oc",
              agent_status = "idle",
              cwd = "/home/ecs-user/workerspace",
              terminal_title_stripped = "OC | 模型切换测试",
            },
          },
        },
      }),
    }
  end
  if argv[2] == "pane" and argv[3] == "process-info" then
    local running = agent_up
    return {
      code = 0,
      stdout = vim.json.encode({
        result = {
          process_info = {
            shell_pid = 1,
            foreground_processes = running and { { pid = 2 } } or {},
            foreground_process_group_id = running and 2 or 1,
          },
        },
      }),
    }
  end
  if argv[2] == "pane" and (argv[3] == "send-keys" or argv[3] == "send-text") then
    table.insert(mr_log, argv[3] .. ":" .. argv[5])
    if argv[3] == "send-text" and argv[5] == "/quit" then
      agent_up = false -- quit 提交后 agent 退出（前台只剩 shell）
    end
    return { code = 0, stdout = "" }
  end
  if argv[2] == "pane" and argv[3] == "run" then
    table.insert(mr_log, "run:" .. table.concat(argv, ",", 4))
    agent_up = true -- pane run 后 agent 重新在跑（就绪轮询通过）
    return { code = 0, stdout = "" }
  end
  if argv[2] == "agent" and argv[3] == "list" then
    return { code = 0, stdout = vim.json.encode({ result = { agents = {} } }) }
  end
  return { code = 0, stdout = "" }
end)

config_mod.options.tools.opencode.models = {
  ["zhipuai-coding-plan"] = { "glm-5.3", "glm-5.3#high", "glm-5.3-flash" },
}
local saved_ui_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  on_choice("zhipuai-coding-plan/glm-5.3#high")
end

-- 默认 model_apply = "api"：原地切换，同步 post session model，无退出/重启
mr_log = {}
agent_up = true
check(model_restart.switch("opencode") == true, "models 已配置时 switch 受理")
local api_line = nil
for _, e in ipairs(mr_log) do
  if e:find("^api:") then
    api_line = e
  end
end
check(
  api_line ~= nil
    and api_line:find("api:/api/session/ses_hit/model,--data,", 1, true) ~= nil
    and api_line:find('"id":"glm', 1, true)
    and api_line:find('"providerID":"zhipuai-coding-plan"', 1, true)
    and api_line:find('"variant":"high"', 1, true),
  "api 原地切换：post session model（#variant 拆为独立字段，会话按标题定位）"
)
check(not vim.tbl_contains(mr_log, "send-text:/quit"), "原地切换不发送 /quit")
check(#vim.tbl_filter(function(e)
  return e:find("^run:")
end, mr_log) == 0, "原地切换不触发 pane run 重启")

-- api 失败（如未知模型）：报错退出且无其它副作用
mr_api_code = 1
mr_log = {}
check(model_restart.switch("opencode") == true, "api 失败场景 switch 仍受理")
check(#vim.tbl_filter(function(e)
  return e:find("^api:")
end, mr_log) == 1, "api 失败时仅一次 post 调用")
mr_api_code = 0

-- 重启路径（model_apply = nil + 显式 model_resume）：退出 → pane run 模板重启
config_mod.options.tools.opencode.model_apply = nil
config_mod.options.tools.opencode.model_resume = { "opencode", "--session", "{session}" }
vim.ui.select = function(items, opts, on_choice)
  on_choice("zhipuai-coding-plan/glm-5.3-flash")
end
mr_log = {}
agent_up = true
check(model_restart.switch("opencode") == true, "重启路径 switch 受理")
local mr_done = vim.wait(8000, function()
  for _, e in ipairs(mr_log) do
    if e:find("^run:") then
      return true
    end
  end
  return false
end)
check(mr_done, "切换流程走完 退出→重启（run 已发出）")
local quit_sent, run_line = false, nil
for _, e in ipairs(mr_log) do
  if e == "send-text:/quit" then
    quit_sent = true
  end
  if e:find("^run:") then
    run_line = e
  end
end
check(quit_sent, "优雅退出先发送 quit_cmd（默认 /quit）")
check(vim.tbl_contains(mr_log, "send-keys:enter"), "quit_cmd 后补回车提交")
check(run_line == "run:p-oc,opencode,--session,ses_hit", "pane run 按模板重启（含捕获的会话 id）")
-- 终端复位顺序断言：复位载荷 → 补 ctrl+c 清行 → pane run，
-- 保证启动命令不与遗留模式产生的残留字节粘连
local reset_prefix = "send-text:\rprintf"
local reset_idx, clear_idx, run_idx
for i, e in ipairs(mr_log) do
  if not reset_idx and e:sub(1, #reset_prefix) == reset_prefix then
    reset_idx = i
  end
  if not run_idx and e:sub(1, 4) == "run:" then
    run_idx = i
  end
  if reset_idx and not clear_idx and not run_idx and e == "send-keys:ctrl+c" then
    clear_idx = i
  end
end
check(
  reset_idx ~= nil and run_idx ~= nil and reset_idx < run_idx,
  "重启前先发终端复位载荷（先于 pane run）"
)
check(
  clear_idx ~= nil and reset_idx < clear_idx and clear_idx < run_idx,
  "复位后、启动前再补一次 ctrl+c 清行（启动命令不与残留字节粘连）"
)
-- 恢复 opencode 默认（api 原地切换），避免影响后续用例
config_mod.options.tools.opencode.model_apply = "api"
config_mod.options.tools.opencode.model_resume = nil
vim.ui.select = saved_ui_select
utils.set_exec(nil)
utils.set_exec_async(nil)
_ = saved_exec

-- ---------------------------------------------------------------------------
-- 工具切换（replace_tool，<leader>ht / :AISwitch）：旧 agent（如 codex）退出后
-- 在同一 pane 重启新工具 —— 模拟"遗留 kitty/鼠标模式 + 输入行被污染"场景，
-- 断言终端复位载荷先于启动命令、复位后启动前再清行，opencode 原样启动不粘连
-- ---------------------------------------------------------------------------
local sw_log = {}
local sw_agent_up = false -- 旧 agent 已退出（pane 是 shell），run 后新 agent 上前台
utils.set_exec(function(argv)
  table.insert(argv_log, argv)
  if argv[2] == "pane" and argv[3] == "current" then
    return { code = 0, stdout = vim.json.encode({ result = { pane = { tab_id = "t1" } } }) }
  end
  if argv[2] == "pane" and argv[3] == "list" then
    return {
      code = 0,
      stdout = vim.json.encode({
        result = {
          panes = {
            {
              label = "codex",
              tab_id = "t1",
              pane_id = "p-cx",
              agent_status = "idle",
              cwd = "/home/ecs-user/workerspace",
            },
          },
        },
      }),
    }
  end
  if argv[2] == "pane" and argv[3] == "process-info" then
    return {
      code = 0,
      stdout = vim.json.encode({
        result = {
          process_info = {
            shell_pid = 1,
            foreground_processes = sw_agent_up and { { pid = 2 } } or {},
            foreground_process_group_id = sw_agent_up and 2 or 1,
          },
        },
      }),
    }
  end
  if argv[2] == "pane" and (argv[3] == "send-keys" or argv[3] == "send-text") then
    table.insert(sw_log, argv[3] .. ":" .. argv[5])
    return { code = 0, stdout = "" }
  end
  if argv[2] == "pane" and (argv[3] == "run" or argv[3] == "rename") then
    table.insert(sw_log, argv[3] .. ":" .. table.concat(argv, ",", 4))
    if argv[3] == "run" then
      sw_agent_up = true -- 启动命令发出后新 agent 成为前台进程（就绪轮询通过）
    end
    return { code = 0, stdout = "" }
  end
  if argv[2] == "agent" and argv[3] == "list" then
    return { code = 0, stdout = vim.json.encode({ result = { agents = {} } }) }
  end
  return { code = 0, stdout = "" }
end)

check(chat_mod.replace_tool("codex", "opencode") == true, "旧 agent 已退出时直接走同 pane 重启分支")
local sw_done = vim.wait(4000, function()
  for _, e in ipairs(sw_log) do
    if e:sub(1, 4) == "run:" then
      return true
    end
  end
  return false
end)
check(sw_done, "切换流程走到 pane run 启动新工具")
local sw_reset_idx, sw_clear_idx, sw_run_idx, sw_run_line
for i, e in ipairs(sw_log) do
  if not sw_reset_idx and e:sub(1, #reset_prefix) == reset_prefix then
    sw_reset_idx = i
  end
  if not sw_run_idx and e:sub(1, 4) == "run:" then
    sw_run_idx = i
    sw_run_line = e
  end
  if sw_reset_idx and not sw_clear_idx and not sw_run_idx and e == "send-keys:ctrl+c" then
    sw_clear_idx = i
  end
end
check(
  sw_reset_idx ~= nil and sw_run_idx ~= nil and sw_reset_idx < sw_run_idx,
  "工具切换：终端复位载荷先于启动命令发出"
)
check(
  sw_clear_idx ~= nil and sw_reset_idx < sw_clear_idx and sw_clear_idx < sw_run_idx,
  "工具切换：复位后、启动前再补一次 ctrl+c 清行"
)
check(sw_run_line == "run:p-cx,opencode", "启动命令原样发出（opencode 未与残留字节粘连）")
utils.set_exec(nil)
utils.set_exec_async(nil)

-- 恢复真实执行器
utils.set_exec(nil)
utils.set_exec_async(nil)
delivery._reset()

print("ALL PASSED")
