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
check(
  select(2, pcall(require, "herder-agents.tools")) ~= nil,
  "外部后端注册机制已移除（herdr-only，tools.lua 已删除）"
)

-- commands
local cmds = vim.api.nvim_get_commands({})
check(cmds.AIToggle ~= nil, ":AIToggle 已创建")
check(cmds.AISwitch ~= nil, ":AISwitch 已创建")

-- 状态
check(vim.g.ai_tool == "opencode", "vim.g.ai_tool 默认 opencode")
check(vim.o.autoread, "autoread 已开启")

-- 工具列表（唯一表示：config.options.tool_order）
local cfg = require("herder-agents.config")
local names = cfg.options.tool_order
check(names[1] == "opencode", "切换器首项为 opencode")
check(vim.tbl_contains(names, "mycli"), "setup 新增工具 mycli 已注册")
check(vim.tbl_contains(names, "hermes"), "默认工具 hermes 已注册")
check(cfg.options.switch_replace == true, "switch_replace 默认开启")

-- opencode 默认不配置 models：<leader>hm 走 model_switch 对话框兜底
local oc_models = cfg.options.tools.opencode.models
check(oc_models == nil, "opencode 默认不配置 models（走 model_switch 兜底）")

-- 工具切换（config.set_current_tool 校验 + 通知 + 写 vim.g.ai_tool）
check(cfg.set_current_tool("codex"), "set codex 成功")
check(vim.g.ai_tool == "codex", "vim.g.ai_tool 已切换")
check(cfg.current_tool() == "codex", "current_tool() 返回 codex")
check(not cfg.set_current_tool("nonexistent"), "set 未知工具返回 false")
check(cfg.set_current_tool("opencode"), "切回 opencode")

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
  -- 模拟服务端：agent wait 成功后该 pane 解除为 unknown
  --（codex 屏幕识别：弹窗关掉/回合结束后停在 unknown，idle 不可达）
  if argv[2] == "agent" and argv[3] == "wait" then
    fake_agents[argv[4]] = "unknown"
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

-- 1b) agent 通道 + 结尾 @文件（附件块形状）→ 原文补一个空格关补全
-- （服务端补按的回车否则会被"接受补全"吃掉，消息不提交）
fake_agents = { ["p-agent"] = "idle" }
argv_log = {}
delivery.deliver("p-agent", "codex", "review this\n\nRelate file:\n- @src/foo.lua", { submit_key = "enter" })
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[5] == "review this\n\nRelate file:\n- @src/foo.lua "
  end),
  "agent prompt：结尾 @token 补一个空格（关闭补全弹层）"
)
argv_log = {}
delivery.deliver("p-agent", "codex", "- $my-skill", { submit_key = "enter" })
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[5] == "- $my-skill "
  end),
  "agent prompt：结尾 $技能 token 同样补空格"
)
argv_log = {}
delivery.deliver("p-agent", "codex", "plain text ending.", { submit_key = "enter" })
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[5] == "plain text ending."
  end),
  "agent prompt：普通结尾原文直传不加空格"
)

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

-- 4) 注册但状态 unknown（codex 屏幕识别常态：回合结束后 idle 不可达）→
--    排队经 settle 复查后直接 agent prompt 送出，不再走 agent wait
--   （wait 等 idle/working 对 codex 永远超时，旧版因此消息永久排队死锁）
delivery._reset()
fake_agents = { ["p-unknown"] = "unknown" }
argv_log = {}
local ok_q = delivery.deliver("p-unknown", "codex", "queued hello", { submit_key = "enter" })
check(ok_q == true and delivery.pending_count() == 1, "unknown 状态进入排队（settle 复查后送出）")
vim.wait(3000, function()
  return delivery.pending_count() == 0
end, 20)
check(delivery.pending_count() == 0, "unknown 经 settle 复查后自动 flush（不再死锁）")
check(not argv_contains(function(argv)
  return argv[3] == "wait"
end), "unknown 不再调用 agent wait（旧版对 codex 无限超时）")
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[4] == "p-unknown"
  end),
  "unknown flush 后经 agent prompt 提交"
)

-- 4b) blocked（审批弹窗）→ 排队等待，不向弹窗送输入；弹窗解除（→ unknown）
--     后经 agent wait 返回 + settle 复查，最终 agent prompt 送出
delivery._reset()
fake_agents = { ["p-blocked"] = "blocked" }
argv_log = {}
delivery.deliver("p-blocked", "codex", "hello", { submit_key = "enter" })
check(delivery.pending_count() == 1, "blocked 状态进入排队（不向弹窗送输入）")
vim.wait(4000, function()
  return delivery.pending_count() == 0
end, 20)
check(delivery.pending_count() == 0, "blocked 解除后自动 flush")
check(
  argv_contains(function(argv)
    return argv[3] == "wait" and argv[4] == "p-blocked" and vim.tbl_contains(argv, "unknown")
  end),
  "blocked 经 agent wait 等待（匹配集含 unknown）"
)
check(
  argv_contains(function(argv)
    return argv[3] == "prompt" and argv[4] == "p-blocked"
  end),
  "blocked 解除后经 agent prompt 提交"
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
local panes = require("herder-agents.panes")
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

panes.interrupt("opencode")
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
panes.interrupt("omp")
vim.wait(600, function()
  return false
end)
check(#send_keys_log == 1 and send_keys_log[1].key == "esc", "omp 单键中断不变（仍是一个 esc）")

-- ---------------------------------------------------------------------------
-- pane 复用（现场回归：ho 连按多开 opencode pane）：
-- 复用谓词只认「当前 tab 内 label == 工具名」，而现场既有 agent pane 的 label
-- 是工单号等自定义值（或无 label）→ 每次 toggle 都 miss → 再 split 一个新实例。
-- 修复后的三级匹配：① 当前 tab label 命中（原语义）② 任意 tab 同 cwd 且
-- label 命中 ③ 任意 tab 同 cwd 且 herdr agent 检测命中（进程级，无需 session，
-- 实测 pane run opencode 后 ≤500ms 即出现 agent 字段），有 agent_session 优先。
-- ---------------------------------------------------------------------------
local saved_env = vim.env.HERDR_ENV
vim.env.HERDR_ENV = "1"
local cur_cwd = vim.fn.getcwd()

-- 可重置的假执行器：pane current/list 按需应答，其余空成功；argv 全记录
local mk_fake = function(pane_tbl, cur_tab, cur_pane_id)
  local argv_log = {}
  local exec = function(argv)
    table.insert(argv_log, argv)
    if argv[2] == "pane" and argv[3] == "current" then
      return {
        code = 0,
        stdout = vim.json.encode({ result = { pane = { tab_id = cur_tab, pane_id = cur_pane_id } } }),
      }
    end
    if argv[2] == "pane" and argv[3] == "list" then
      return { code = 0, stdout = vim.json.encode({ result = { panes = pane_tbl } }) }
    end
    if argv[2] == "pane" and argv[3] == "split" then
      return { code = 0, stdout = vim.json.encode({ result = { pane = { pane_id = "p-created" } } }) }
    end
    return { code = 0, stdout = "" }
  end
  local clear = function()
    for i = #argv_log, 1, -1 do
      argv_log[i] = nil
    end
  end
  return exec, argv_log, clear
end
local function saw(argv_log, pred)
  for _, argv in ipairs(argv_log) do
    if pred(argv) then
      return true
    end
  end
  return false
end
local is_split = function(argv)
  return argv[2] == "pane" and argv[3] == "split"
end

-- 现场形态：同 tab（t2 = nvim 所在 tab）已有两个 opencode pane——
-- p-live：working agent，自定义 label（工单号）；p-stray：无 label 无 session 的裸 TUI。
-- 旧行为：label 都不是 "opencode" → lookup miss → toggle 再 split 新实例
local live_panes = {
  {
    label = "31566321",
    tab_id = "t2",
    pane_id = "p-live",
    cwd = cur_cwd,
    agent = "opencode",
    agent_session = { value = "ses_live" },
  },
  { tab_id = "t2", pane_id = "p-stray", cwd = cur_cwd, agent = "opencode" },
}
local live_exec, live_log, live_clear = mk_fake(live_panes, "t2", "p-nvim")
utils.set_exec(live_exec)

local reused = panes.lookup("opencode")
check(
  reused ~= nil and reused.pane_id == "p-live",
  "现场形态：lookup 收编自定义 label 的 agent pane（有 session 优先于裸 TUI）"
)

-- toggle：不 split 第二个实例，而是放大复用的 pane（同 tab 无需切 tab）
live_clear()
panes.toggle("opencode")
check(not saw(live_log, is_split), "现场形态：toggle 不再 split 新实例")
check(
  saw(live_log, function(argv)
    return argv[2] == "pane" and argv[3] == "zoom" and vim.tbl_contains(argv, "p-live")
  end),
  "现场形态：toggle 放大复用的 agent pane"
)

-- interrupt：中断键发往复用的 pane 而非报 "pane not found"
live_clear()
panes.interrupt("opencode")
local live_esc = vim.wait(2000, function()
  local n = 0
  for _, argv in ipairs(live_log) do
    if argv[2] == "pane" and argv[3] == "send-keys" and vim.tbl_contains(argv, "p-live") then
      n = n + 1
    end
  end
  return n >= 2
end)
local live_keys = {}
for _, argv in ipairs(live_log) do
  if argv[2] == "pane" and argv[3] == "send-keys" then
    table.insert(live_keys, argv[5])
  end
end
check(
  live_esc and #live_keys >= 2 and live_keys[2] == "esc",
  "现场形态：中断序列（esc esc）发往复用的 pane"
)

-- 跨 tab 同路径复用：两个 tab 开同一路径，tab 2 的 nvim 复用 tab 1 的 pane，
-- 跳过无 cwd / 异路径候选（注意：无 cwd 的候选不得放在当前 tab 且带 label，
-- 否则命中①级「当前 tab label」——那是原语义，cwd 不参与）
local xtab_panes = {
  { label = "opencode", tab_id = "t1", pane_id = "p-oc1", cwd = cur_cwd },
  { label = "opencode", tab_id = "t9", pane_id = "p-oc9", cwd = "/somewhere-else" },
  { label = "opencode", tab_id = "t3", pane_id = "p-no-cwd" },
}
local xtab_exec, xtab_log, xtab_clear = mk_fake(xtab_panes, "t2", "p-nvim2")
utils.set_exec(xtab_exec)
check(
  panes.lookup("opencode").pane_id == "p-oc1",
  "跨 tab 同路径：lookup 复用 t1 的 opencode pane（跳过无 cwd / 异路径候选）"
)
xtab_clear()
panes.toggle("opencode")
check(
  saw(xtab_log, function(argv)
    return argv[2] == "tab" and argv[3] == "focus" and argv[4] == "t1"
  end),
  "跨 tab 同路径：toggle 切换焦点到 agent 所在 tab"
)
check(
  saw(xtab_log, function(argv)
    return argv[2] == "pane" and argv[3] == "zoom" and vim.tbl_contains(argv, "p-oc1")
  end),
  "跨 tab 同路径：toggle 放大复用的 pane"
)
check(not saw(xtab_log, is_split), "跨 tab 同路径：toggle 不再 split 第二个实例")

-- ①级优先：当前 tab 已有 label 命中的 pane（即使 cwd 不同）时不跨 tab、
-- 且保持原 zoom-toggle 语义（layout --current + zoom 当前 pane，不 tab focus）
local intab_panes = {
  { label = "opencode", tab_id = "t2", pane_id = "p-in-tab", cwd = "/elsewhere" },
  { label = "opencode", tab_id = "t1", pane_id = "p-oc1", cwd = cur_cwd },
}
local intab_exec, intab_log, intab_clear = mk_fake(intab_panes, "t2", "p-nvim2")
utils.set_exec(intab_exec)
check(panes.lookup("opencode").pane_id == "p-in-tab", "当前 tab 的同名 pane 优先于跨 tab / agent 匹配")
intab_clear()
panes.toggle("opencode")
check(not saw(intab_log, is_split), "当前 tab 同名 pane：toggle 不 split")
check(saw(intab_log, function(argv)
  return argv[2] == "pane" and argv[3] == "layout"
end) and not saw(intab_log, function(argv)
  return argv[2] == "tab" and argv[3] == "focus"
end), "当前 tab 同名 pane：保持 zoom-toggle 语义（不切 tab）")

-- ②级优先于③级：同 cwd 有 label 命中 pane 时，不用 agent 检测的候选
local mixed_panes = {
  { tab_id = "t2", pane_id = "p-agent", cwd = cur_cwd, agent = "opencode", agent_session = { value = "s1" } },
  { label = "opencode", tab_id = "t1", pane_id = "p-labeled", cwd = cur_cwd },
}
utils.set_exec(mk_fake(mixed_panes, "t2", "p-nvim2"))
check(panes.lookup("opencode").pane_id == "p-labeled", "label 命中优先于 agent 检测命中")

-- 误收编防护：异 cwd 的 agent pane、同 cwd 但不同 agent（codex）都不命中
local neg_panes = {
  { tab_id = "t9", pane_id = "p-far", cwd = "/somewhere-else", agent = "opencode", agent_session = { value = "s9" } },
  { tab_id = "t2", pane_id = "p-codex", cwd = cur_cwd, agent = "codex", agent_session = { value = "s2" } },
  { label = "opencode", tab_id = "t9", pane_id = "p-oc9", cwd = "/somewhere-else" },
}
utils.set_exec(mk_fake(neg_panes, "t2", "p-nvim2"))
check(panes.lookup("opencode") == nil, "异 cwd / 异 agent 的 pane 不被收编，lookup 返回 nil")

-- 一次 toggle 恰好 split 一次；连续 toggle（rename 已生效）复用不追加 split；
-- 「重启 nvim 后接管」同一谓词覆盖：插件无内存态，每次都查 pane list
local world = {}
local fresh_exec, fresh_log, fresh_clear = mk_fake(world, "t2", "p-nvim")
utils.set_exec(fresh_exec)
panes.toggle("opencode")
local split_n = 0
for _, argv in ipairs(fresh_log) do
  if is_split(argv) then
    split_n = split_n + 1
  end
end
check(split_n == 1, "全新环境：一次 toggle 恰好 split 一次（无重复创建路径）")
-- 模拟 split+rename 落地后的世界（实测 rename 立即反映到 pane list）：
-- 新 nvim 进程（无任何内存态）按 ho 应直接接管该 pane
table.insert(world, { label = "opencode", tab_id = "t2", pane_id = "p-created", cwd = cur_cwd })
fresh_clear()
panes.toggle("opencode")
check(not saw(fresh_log, is_split), "连续/重启后：接管既有 pane，不再 split")
check(
  saw(fresh_log, function(argv)
    return argv[2] == "pane" and argv[3] == "layout"
  end),
  "连续/重启后：走 zoom-toggle 分支接管（layout --current + zoom 当前 pane）"
)

utils.set_exec(nil)
utils.set_exec_async(nil)
if saved_env then
  vim.env.HERDR_ENV = saved_env
else
  vim.env.HERDR_ENV = nil
end

-- ---------------------------------------------------------------------------
-- 宽度 toggle（:HerdrShrinkToggle）：调整 nvim 在其归属 split 内容宽中的
-- 占比（标准布局即全 tab 宽），在两个固定锚点间切换：toggle_ratio（默认
-- 0.32）↔ 默认分屏比例 split.ratio（默认 0.55）。amount 语义（活体标定）=
-- 被推边界所属 split 的 ratio 增量 —— fixture 必须带 splits 字段。与 tab 内
-- pane 数量无关（agent 再 split 出新 pane 也照常工作）：收窄 = 邻侧 pane 吃进
-- （推 nvim|邻侧 分界），恢复 = 直接扩张 nvim。无状态（曾按按压时比例记基准，
-- 窄态/连按会污染成窄值死循环）；zoomed / 上下布局 / 独占 tab / 邻距异常时
-- 守卫拦截
-- ---------------------------------------------------------------------------
vim.env.HERDR_ENV = "1"
local function mk_layout_fake(pane_tbl, layout_tbl, cur_tab, cur_pane_id, resize_result)
  local argv_log = {}
  local exec = function(argv)
    table.insert(argv_log, argv)
    if argv[2] == "pane" and argv[3] == "current" then
      return {
        code = 0,
        stdout = vim.json.encode({ result = { pane = { tab_id = cur_tab, pane_id = cur_pane_id } } }),
      }
    end
    if argv[2] == "pane" and argv[3] == "list" then
      return { code = 0, stdout = vim.json.encode({ result = { panes = pane_tbl } }) }
    end
    if argv[2] == "pane" and argv[3] == "layout" then
      return { code = 0, stdout = vim.json.encode({ result = { layout = layout_tbl } }) }
    end
    if argv[2] == "pane" and argv[3] == "resize" then
      return { code = 0, stdout = vim.json.encode({ result = { resize = resize_result or { changed = true } } }) }
    end
    return { code = 0, stdout = "" }
  end
  local clear = function()
    for i = #argv_log, 1, -1 do
      argv_log[i] = nil
    end
  end
  return exec, argv_log, clear
end
local function resize_calls(argv_log)
  local calls = {}
  for _, argv in ipairs(argv_log) do
    if argv[2] == "pane" and argv[3] == "resize" then
      local opts = {}
      for i = 4, #argv, 2 do
        opts[argv[i]] = argv[i + 1]
      end
      table.insert(calls, opts)
    end
  end
  return calls
end

-- 布局：nvim 左 130 cols + agent 右 70 cols（agent 在右，当前占比 0.65）
-- toggle_ratio 默认 0.32：收窄后布局为 nvim 64 / agent 136（64/200 = 0.32）
-- 语义：nvim 占其归属 split 内容宽的比例（标准 root split 布局下即全 tab 宽）
local st_panes = { { label = "opencode", tab_id = "t2", pane_id = "p-agent", cwd = vim.fn.getcwd() } }
local function layout_of(nvim_w, agent_w)
  return {
    zoomed = false,
    panes = {
      { pane_id = "p-nvim", rect = { x = 0, y = 0, width = nvim_w, height = 60 } },
      { pane_id = "p-agent", rect = { x = nvim_w, y = 0, width = agent_w, height = 60 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = nvim_w / (nvim_w + agent_w), rect = { x = 0, y = 0, width = nvim_w + agent_w, height = 60 } },
    },
  }
end

-- 首按：收窄 0.65 → 0.32（邻 pane 在右 → agent 向左吃进，amount = 0.33）
local st_exec, st_log, st_clear = mk_layout_fake(st_panes, layout_of(130, 70), "t2", "p-nvim")
utils.set_exec(st_exec)
panes.shrink_toggle("opencode")
local st_calls = resize_calls(st_log)
check(
  #st_calls == 1
    and st_calls[1]["--pane"] == "p-agent"
    and st_calls[1]["--direction"] == "left"
    and st_calls[1]["--amount"] == "0.3300",
  "宽度 toggle：首按收窄（邻 pane 吃进，方向/比例差正确）"
)
check(vim.g.herd_shrink_state == nil, "宽度 toggle：固定锚点切换，不写 vim.g 基准")

-- 再按：0.32 → 默认分屏比例 0.55：直接向右扩张 nvim 自身（amount = 0.55-0.32）
local st2_exec, st2_log = mk_layout_fake(st_panes, layout_of(64, 136), "t2", "p-nvim")
utils.set_exec(st2_exec)
panes.shrink_toggle("opencode")
st_calls = resize_calls(st2_log)
check(
  #st_calls == 1
    and st_calls[1]["--pane"] == "p-nvim"
    and st_calls[1]["--direction"] == "right"
    and st_calls[1]["--amount"] == "0.2300",
  "宽度 toggle：再按恢复默认分屏比例 0.55（直接扩张 nvim）"
)

-- agent 在左侧的镜像：nvim x=70 w=130，agent x=0 w=70 → 收窄 = agent 向右吃进
-- nvim 是 root split 的右孩子：ratio 0.35（边界 x=70），nvim 占比 = 1−0.35
local mirror_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 70, y = 0, width = 130, height = 60 } },
    { pane_id = "p-agent", rect = { x = 0, y = 0, width = 70, height = 60 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 0.35, rect = { x = 0, y = 0, width = 200, height = 60 } },
  },
}
local mi_exec, mi_log = mk_layout_fake(st_panes, mirror_layout, "t2", "p-nvim")
utils.set_exec(mi_exec)
panes.shrink_toggle("opencode")
local mi_calls = resize_calls(mi_log)
check(
  #mi_calls == 1
    and mi_calls[1]["--pane"] == "p-agent"
    and mi_calls[1]["--direction"] == "right"
    and mi_calls[1]["--amount"] == "0.3300",
  "宽度 toggle：邻 pane 在左时方向镜像（agent 向右吃进）"
)

-- 镜像再按：nvim x=136 w=64（32%）→ 恢复 55%：直接向左扩张 nvim 自身
-- nvim 是 root split 的右孩子：ratio 0.68（边界 x=136），nvim 占比 = 1−0.68 = 0.32
local mr_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-agent", rect = { x = 0, y = 0, width = 136, height = 60 } },
    { pane_id = "p-nvim", rect = { x = 136, y = 0, width = 64, height = 60 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 0.68, rect = { x = 0, y = 0, width = 200, height = 60 } },
  },
}
local mr_exec, mr_log = mk_layout_fake(st_panes, mr_layout, "t2", "p-nvim")
utils.set_exec(mr_exec)
panes.shrink_toggle("opencode")
local mr_calls = resize_calls(mr_log)
check(
  #mr_calls == 1
    and mr_calls[1]["--pane"] == "p-nvim"
    and mr_calls[1]["--direction"] == "left"
    and mr_calls[1]["--amount"] == "0.2300",
  "宽度 toggle：邻 pane 在左时再按恢复（nvim 向左扩张）"
)

-- 守卫：zoomed → 不 resize
local zm_exec, zm_log = mk_layout_fake(st_panes, { zoomed = true, panes = layout_of(130, 70).panes }, "t2", "p-nvim")
utils.set_exec(zm_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(zm_log) == 0, "宽度 toggle：zoomed 时拦截")

-- 守卫：上下布局（左右都没有紧邻 pane）→ 不 resize
-- fixture 带 direction=="down" 的 split：纵 split 不参与横向归属判定
local stacked_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 200, height = 30 } },
    { pane_id = "p-agent", rect = { x = 0, y = 30, width = 200, height = 30 } },
  },
  splits = {
    { id = "split_0_root", direction = "down", ratio = 0.5, rect = { x = 0, y = 0, width = 200, height = 60 } },
  },
}
local sk_exec, sk_log = mk_layout_fake(st_panes, stacked_layout, "t2", "p-nvim")
utils.set_exec(sk_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(sk_log) == 0, "宽度 toggle：上下布局（无左右紧邻）拦截")

-- 守卫：tab 内只有 nvim 一个 pane → 无邻可推，不 resize
local solo_layout = {
  zoomed = false,
  panes = { { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 244, height = 61 } } },
  splits = {},
}
local solo_exec, solo_log = mk_layout_fake(st_panes, solo_layout, "t2", "p-nvim")
utils.set_exec(solo_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(solo_log) == 0, "宽度 toggle：tab 内仅 nvim 一个 pane 时拦截")

-- 真实布局回归（实测 Herdr capture）：左右相邻 pane 之间有 1 列 divider ——
-- nvim rect={x=0,y=0,width=134,height=61}，opencode rect={x=135,y=0,width=110,
-- height=61}，area.width=245=134+1+110。精确边缘相等会误报「不相邻」，
-- 相邻判定必须容忍 1 列分界线（0 间距布局仍兼容，见上文 layout_of 用例）
local function divider_layout(nvim_w, agent_w)
  local total = nvim_w + 1 + agent_w
  return {
    zoomed = false,
    panes = {
      { pane_id = "p-nvim", rect = { x = 0, y = 0, width = nvim_w, height = 61 } },
      { pane_id = "p-agent", rect = { x = nvim_w + 1, y = 0, width = agent_w, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = nvim_w / total, rect = { x = 0, y = 0, width = total, height = 61 } },
    },
  }
end

-- 首按：root ratio = 134/245 ≈ 0.5469 → 收窄到 0.32（agent 在右 → direction
-- left，amount = 0.5469−0.32 = 0.2269；旧 bug 公式按 pane 宽做分母会算 0.2292）
local dv_exec, dv_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
utils.set_exec(dv_exec)
panes.shrink_toggle("opencode")
local dv_calls = resize_calls(dv_log)
check(
  #dv_calls == 1
    and dv_calls[1]["--pane"] == "p-agent"
    and dv_calls[1]["--direction"] == "left"
    and dv_calls[1]["--amount"] == "0.2269",
  "宽度 toggle：1 列 divider 相邻（agent 右）首按收窄（真实布局回归）"
)

-- 成功的宽度调整屏幕直接可见，不弹通知；拦截类守卫仍提示（否则不知道为何没反应）
local saved_notify = vim.notify
local notify_log = {}
vim.notify = function(msg)
  table.insert(notify_log, tostring(msg))
end
local q_exec, q_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
utils.set_exec(q_exec)
panes.shrink_toggle("opencode")
check(
  #resize_calls(q_log) == 1 and #notify_log == 0,
  "宽度 toggle：成功收窄不弹通知（屏幕直接可见）"
)
local q2_exec, q2_log = mk_layout_fake(st_panes, divider_layout(78, 166), "t2", "p-nvim")
utils.set_exec(q2_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(q2_log) == 1 and #notify_log == 0, "宽度 toggle：成功恢复默认比例不弹通知")
local q3_exec, q3_log = mk_layout_fake(st_panes, stacked_layout, "t2", "p-nvim")
utils.set_exec(q3_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(q3_log) == 0 and #notify_log >= 1, "宽度 toggle：不相邻拦截仍弹提示")
vim.notify = saved_notify
-- 再按：布局变为 nvim 78 / agent 166（x=79，仍隔 1 列）→ 恢复默认分屏比例 0.55
-- （root ratio = 78/245 ≈ 0.3184 已在恢复死区 → 直接向右扩张 nvim 自身，
-- amount = 0.55−0.3184 = 0.2316）
local rv_exec, rv_log = mk_layout_fake(st_panes, divider_layout(78, 166), "t2", "p-nvim")
utils.set_exec(rv_exec)
panes.shrink_toggle("opencode")
local rv_calls = resize_calls(rv_log)
check(
  #rv_calls == 1
    and rv_calls[1]["--pane"] == "p-nvim"
    and rv_calls[1]["--direction"] == "right"
    and rv_calls[1]["--amount"] == "0.2316",
  "宽度 toggle：1 列 divider 再按恢复默认分屏比例（扩张 nvim）"
)

-- 自愈回归：窄态（16%，曾被记成基准导致 16%↔32% 死循环）按压 → 直接切到
-- 32%（实为放大 nvim），不记忆 16%；再按回到默认 55%（上例），而非 16%
local nh_exec, nh_log = mk_layout_fake(st_panes, divider_layout(39, 205), "t2", "p-nvim")
utils.set_exec(nh_exec)
panes.shrink_toggle("opencode")
local nh_calls = resize_calls(nh_log)
check(
  #nh_calls == 1
    and nh_calls[1]["--pane"] == "p-nvim"
    and nh_calls[1]["--direction"] == "right"
    and nh_calls[1]["--amount"] == "0.1608",
  "宽度 toggle：窄态 16% 按压自愈切到 32%（放大，不记窄基准）"
)
check(vim.g.herd_shrink_state == nil, "宽度 toggle：窄态按压后仍不写 vim.g 基准")

-- agent 在左镜像：agent x=0 w=110，nvim x=111 w=134 → 收窄 = agent 向右吃进
-- nvim 是 root split 的右孩子：ratio 110/245 ≈ 0.4490（边界 x=110），amount
-- = (1−0.32)−0.4490 = 0.2310
local ml_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-agent", rect = { x = 0, y = 0, width = 110, height = 61 } },
    { pane_id = "p-nvim", rect = { x = 111, y = 0, width = 134, height = 61 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 110 / 245, rect = { x = 0, y = 0, width = 245, height = 61 } },
  },
}
local ml_exec, ml_log = mk_layout_fake(st_panes, ml_layout, "t2", "p-nvim")
utils.set_exec(ml_exec)
panes.shrink_toggle("opencode")
local ml_calls = resize_calls(ml_log)
check(
  #ml_calls == 1
    and ml_calls[1]["--pane"] == "p-agent"
    and ml_calls[1]["--direction"] == "right"
    and ml_calls[1]["--amount"] == "0.2310",
  "宽度 toggle：1 列 divider 邻 pane 在左时方向镜像"
)

-- 镜像 divider 再按恢复：agent x=0 w=166，nvim x=167 w=78 → nvim 向左扩张
-- ratio 166/245 ≈ 0.6776，nvim 占比 0.3224（恢复死区内）→ amount = 0.6776−0.45
local ml2_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-agent", rect = { x = 0, y = 0, width = 166, height = 61 } },
    { pane_id = "p-nvim", rect = { x = 167, y = 0, width = 78, height = 61 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 166 / 245, rect = { x = 0, y = 0, width = 245, height = 61 } },
  },
}
local ml2_exec, ml2_log = mk_layout_fake(st_panes, ml2_layout, "t2", "p-nvim")
utils.set_exec(ml2_exec)
panes.shrink_toggle("opencode")
local ml2_calls = resize_calls(ml2_log)
check(
  #ml2_calls == 1
    and ml2_calls[1]["--pane"] == "p-nvim"
    and ml2_calls[1]["--direction"] == "left"
    and ml2_calls[1]["--amount"] == "0.2276",
  "宽度 toggle：1 列 divider 镜像再按恢复（nvim 向左扩张）"
)

-- 守卫：最近邻 gap > 1（≥2 列，无法归因于分界线，布局异常）→ 不 resize
local g2_layout = divider_layout(134, 110)
g2_layout.panes[2].rect.x = 136 -- nvim 右缘 134，agent 左缘 136
local g2_exec, g2_log = mk_layout_fake(st_panes, g2_layout, "t2", "p-nvim")
utils.set_exec(g2_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(g2_log) == 0, "宽度 toggle：gap>1（2 列）拦截不 resize")

-- 守卫：rect 重叠（边缘 gap 为负，布局异常）→ 不 resize
local ov_layout = divider_layout(134, 110)
ov_layout.panes[2].rect.x = 100
local ov_exec, ov_log = mk_layout_fake(st_panes, ov_layout, "t2", "p-nvim")
utils.set_exec(ov_exec)
panes.shrink_toggle("opencode")
check(#resize_calls(ov_log) == 0, "宽度 toggle：pane rect 重叠时拦截")

-- 多 pane（中间隔无关 pane）：nvim 推的是归属 root split 的边界（nvim|other
-- 分界），与更远的 agent 无关。root ratio = 100/245 ≈ 0.4082 →
-- amount = 0.4082−0.32 = 0.0882（旧 bug 公式按 pane 宽做分母会算 0.1555）
local mid_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 100, height = 61 } },
    { pane_id = "p-other", rect = { x = 101, y = 0, width = 43, height = 61 } },
    { pane_id = "p-agent", rect = { x = 145, y = 0, width = 100, height = 61 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 100 / 245, rect = { x = 0, y = 0, width = 245, height = 61 } },
    { id = "split_1", direction = "right", ratio = 43 / 144, rect = { x = 101, y = 0, width = 144, height = 61 } },
  },
}
local mid_exec, mid_log = mk_layout_fake(st_panes, mid_layout, "t2", "p-nvim")
utils.set_exec(mid_exec)
panes.shrink_toggle("opencode")
local mid_calls = resize_calls(mid_log)
check(
  #mid_calls == 1
    and mid_calls[1]["--pane"] == "p-other"
    and mid_calls[1]["--direction"] == "left"
    and mid_calls[1]["--amount"] == "0.0882",
  "宽度 toggle：中间隔无关 pane 时调 nvim|紧邻 分界（归属 split 的 ratio 语义）"
)

-- 多 pane：右侧上下堆叠列（agent pane 又 split 出新 pane 的形态）——
-- nvim 全高在左，右列两 pane 共享同一条竖直分界，推任一个都移动整列边界。
-- 边界属于 root split：ratio = 134/245 ≈ 0.5469 → amount = 0.5469−0.32 =
-- 0.2269（同两 pane divider 布局，与列内成员宽度无关）；邻居取 gap 最小再最
-- 靠上（p-agent）
local col_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 134, height = 61 } },
    { pane_id = "p-agent", rect = { x = 135, y = 0, width = 110, height = 30 } },
    { pane_id = "p-agent2", rect = { x = 135, y = 31, width = 110, height = 30 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 134 / 245, rect = { x = 0, y = 0, width = 245, height = 61 } },
    { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 135, y = 0, width = 110, height = 61 } },
  },
}
local co_exec, co_log = mk_layout_fake(st_panes, col_layout, "t2", "p-nvim")
utils.set_exec(co_exec)
panes.shrink_toggle("opencode")
local co_calls = resize_calls(co_log)
check(
  #co_calls == 1
    and co_calls[1]["--pane"] == "p-agent"
    and co_calls[1]["--direction"] == "left"
    and co_calls[1]["--amount"] == "0.2269",
  "宽度 toggle：右侧堆叠列（多 pane）收窄 nvim（推整列边界，amount 只看归属 split 的 ratio）"
)

-- 堆叠列再按恢复：nvim 78 / 列 166×2（root ratio = 78/245 ≈ 0.3184 已在恢复
-- 死区）→ 直接扩张 nvim：amount = 0.55−0.3184 = 0.2316
local col2_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 78, height = 61 } },
    { pane_id = "p-agent", rect = { x = 79, y = 0, width = 166, height = 30 } },
    { pane_id = "p-agent2", rect = { x = 79, y = 31, width = 166, height = 30 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 78 / 245, rect = { x = 0, y = 0, width = 245, height = 61 } },
    { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 79, y = 0, width = 166, height = 61 } },
  },
}
local co2_exec, co2_log = mk_layout_fake(st_panes, col2_layout, "t2", "p-nvim")
utils.set_exec(co2_exec)
panes.shrink_toggle("opencode")
local co2_calls = resize_calls(co2_log)
check(
  #co2_calls == 1
    and co2_calls[1]["--pane"] == "p-nvim"
    and co2_calls[1]["--direction"] == "right"
    and co2_calls[1]["--amount"] == "0.2316",
  "宽度 toggle：右侧堆叠列（多 pane）再按恢复（直接扩张 nvim，回到 55% 占比）"
)

-- L 形布局回归（实测复现场景）：邻 pane 不占满 split 对侧（中间隔列）时，
-- 旧 bug 公式（pane 宽做分母）会系统性过冲 —— 预期落 0.32 实际落 0.2667。
-- amount 语义 = 被推边界所属 split 的 ratio 增量：nvim|右列 分界属于 root
-- split（ratio 0.45，边界 x=54）→ 收窄 0.32 = ratio − 0.13，推 p-mid（右列
-- 里 gap 最小且最靠上的成员，代理整列边界）
local lshrink_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 54, height = 40 } },
    { pane_id = "p-mid", rect = { x = 54, y = 0, width = 33, height = 20 } },
    { pane_id = "p-mid2", rect = { x = 87, y = 0, width = 33, height = 20 } },
    { pane_id = "p-agent", rect = { x = 54, y = 20, width = 66, height = 20 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 0.45, rect = { x = 0, y = 0, width = 120, height = 40 } },
    { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 54, y = 0, width = 66, height = 40 } },
    { id = "split_2", direction = "right", ratio = 0.5, rect = { x = 54, y = 0, width = 66, height = 20 } },
  },
}
local ls_exec, ls_log = mk_layout_fake(st_panes, lshrink_layout, "t2", "p-nvim")
utils.set_exec(ls_exec)
panes.shrink_toggle("opencode")
local ls_calls = resize_calls(ls_log)
check(
  #ls_calls == 1
    and ls_calls[1]["--pane"] == "p-mid"
    and ls_calls[1]["--direction"] == "left"
    and ls_calls[1]["--amount"] == "0.1300",
  "宽度 toggle：L 形布局收窄（amount = 归属 split ratio 0.45−0.32；旧公式 0.1793 过冲）"
)

-- L 形从 0.32 恢复：root ratio 已是 0.32（恢复死区内）→ 推 nvim 自身 right，
-- amount = 0.55−0.32 = 0.23
local lrestore_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 38.4, height = 40 } },
    { pane_id = "p-mid", rect = { x = 38.4, y = 0, width = 40.8, height = 20 } },
    { pane_id = "p-mid2", rect = { x = 79.2, y = 0, width = 40.8, height = 20 } },
    { pane_id = "p-agent", rect = { x = 38.4, y = 20, width = 81.6, height = 20 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 120, height = 40 } },
    { id = "split_1", direction = "down", ratio = 0.5, rect = { x = 38.4, y = 0, width = 81.6, height = 40 } },
    { id = "split_2", direction = "right", ratio = 0.5, rect = { x = 38.4, y = 0, width = 81.6, height = 20 } },
  },
}
local lr_exec, lr_log = mk_layout_fake(st_panes, lrestore_layout, "t2", "p-nvim")
utils.set_exec(lr_exec)
panes.shrink_toggle("opencode")
local lr_calls = resize_calls(lr_log)
check(
  #lr_calls == 1
    and lr_calls[1]["--pane"] == "p-nvim"
    and lr_calls[1]["--direction"] == "right"
    and lr_calls[1]["--amount"] == "0.2300",
  "宽度 toggle：L 形布局从收窄锚点恢复（推 nvim 自身 right，amount 0.55−0.32）"
)

-- 落点校验：resize 响应内嵌新 layout 时核对实际占比 —— 服务端最小宽度 clamp
-- 把 root ratio 只推到 0.40（没到 0.32）→ warn；响应无 layout 字段（上文各
-- fake 的现状）→ 静默跳过
local clamped_layout = divider_layout(134, 110)
clamped_layout.splits[1].ratio = 0.40
local saved_notify2 = vim.notify
local notify_log2 = {}
vim.notify = function(msg)
  table.insert(notify_log2, tostring(msg))
end
local cl_exec, cl_log = mk_layout_fake(
  st_panes,
  divider_layout(134, 110),
  "t2",
  "p-nvim",
  { changed = true, layout = clamped_layout }
)
utils.set_exec(cl_exec)
panes.shrink_toggle("opencode")
check(
  #resize_calls(cl_log) == 1 and #notify_log2 == 1,
  "宽度 toggle：clamp 未达目标时告警（响应内嵌 layout，实际 40% ≠ 目标 32%）"
)
local ncl_exec, ncl_log = mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim")
utils.set_exec(ncl_exec)
panes.shrink_toggle("opencode")
check(
  #resize_calls(ncl_log) == 1 and #notify_log2 == 1,
  "宽度 toggle：响应无 layout 字段时静默跳过落点校验"
)
vim.notify = saved_notify2

-- 取最内层归属 split：nvim 同时落在 root（ratio 0.4，边界 x=80）与嵌套右
-- split_1（ratio 0.5，边界 x=140）内 → 取 rect 面积最小者 split_1（nvim 直接
-- 控制的边界），share = 0.5 → amount = 0.5−0.32 = 0.18，推右邻 p-agent。
-- 若误选 root（右孩子，share 0.6）会推 p-left 且 amount 0.28，断言即失败
local nested_layout = {
  zoomed = false,
  panes = {
    { pane_id = "p-left", rect = { x = 0, y = 0, width = 80, height = 60 } },
    { pane_id = "p-nvim", rect = { x = 80, y = 0, width = 60, height = 60 } },
    { pane_id = "p-agent", rect = { x = 140, y = 0, width = 60, height = 60 } },
  },
  splits = {
    { id = "split_0_root", direction = "right", ratio = 0.4, rect = { x = 0, y = 0, width = 200, height = 60 } },
    { id = "split_1", direction = "right", ratio = 0.5, rect = { x = 80, y = 0, width = 120, height = 60 } },
  },
}
local ns_exec, ns_log = mk_layout_fake(st_panes, nested_layout, "t2", "p-nvim")
utils.set_exec(ns_exec)
panes.shrink_toggle("opencode")
local ns_calls = resize_calls(ns_log)
check(
  #ns_calls == 1
    and ns_calls[1]["--pane"] == "p-agent"
    and ns_calls[1]["--direction"] == "left"
    and ns_calls[1]["--amount"] == "0.1800",
  "宽度 toggle：嵌套布局取最内层归属 split（推 split_1 的边界，非 root 边界）"
)

-- 集成：命令已注册、默认不绑键、toggle_ratio 默认 0.35、绑定后生效
check(vim.api.nvim_get_commands({})["HerdrShrinkToggle"] ~= nil, ":HerdrShrinkToggle 已创建")
check(not has_map(" h<", "n"), "默认不绑定 <leader>h<")
check(math.abs(require("herder-agents.config").options.toggle_ratio - 0.32) < 1e-9, "toggle_ratio 默认 0.32")
plugin.setup({
  tools = { mycli = { title = " My CLI Chat " } },
  keys = { shrink_toggle = "<leader>h<" },
})
check(has_map(" h<", "n"), "传入 shrink_toggle 键后注册 <leader>h<")

utils.set_exec(nil)
utils.set_exec_async(nil)
if saved_env then
  vim.env.HERDR_ENV = saved_env
else
  vim.env.HERDR_ENV = nil
end

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

check(panes.replace("codex", "opencode") == true, "旧 agent 已退出时直接走同 pane 重启分支")
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
