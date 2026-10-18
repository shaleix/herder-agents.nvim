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
-- macOS 上 nvim 会把 /tmp 解析成 /private/tmp（symlink），比较前先 resolve
check(vim.fn.resolve(range.path) == vim.fn.resolve("/tmp/herder-agents-notes.lua"), "note_range 返回缓冲区路径")
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
  pattern = { "AIAgentWorking", "AIAgentIdle", "AIAgentBlocked", "AIAgentDone" },
  callback = function(event)
    table.insert(status_events, { match = event.match, data = event.data })
  end,
})
fake_agents = { ["s1"] = "working", ["s2"] = "idle", ["s3"] = "unknown", ["s4"] = "done" }
status_mod._tick()
check(#status_events == 3, "agent list 轮询发出 idle/working/done 事件（unknown 不发）")
local saw_working, saw_cwd, saw_done = false, false, false
for _, ev in ipairs(status_events) do
  if ev.match == "AIAgentWorking" and ev.data.pane_id == "s1" then
    saw_working = true
  end
  if ev.match == "AIAgentDone" and ev.data.pane_id == "s4" then
    saw_done = true
  end
  if ev.data.cwd == "/tmp" then
    saw_cwd = true
  end
end
check(saw_working, "AIAgentWorking 事件 payload 正确")
check(saw_done, "AIAgentDone 事件已发出（done 状态映射，payload 形状一致）")
check(saw_cwd, "事件 payload 含 agent cwd")
status_mod._tick()
check(#status_events == 3, "状态未变不重复发事件")
fake_agents["s2"] = "working"
status_mod._tick()
check(#status_events == 4 and status_events[4].match == "AIAgentWorking", "状态变化发出新事件")
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
      {
        id = "split_0_root",
        direction = "right",
        ratio = nvim_w / (nvim_w + agent_w),
        rect = { x = 0, y = 0, width = nvim_w + agent_w, height = 60 },
      },
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
      {
        id = "split_0_root",
        direction = "right",
        ratio = nvim_w / total,
        rect = { x = 0, y = 0, width = total, height = 61 },
      },
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

do -- 真实布局回归块（局部变量隔离，避免超出 200 局部上限）
  -- 真实布局回归（herdr 0.9.3 用户现场 capture，tab w6C:t1）：root ratio
  -- 0.32 × 宽 245 → 边界 78.4；herdr 取整落位（40 个真实 tab 布局标定）：
  -- 边界列 = round(rect.x+ratio*rect.width)，右孩子从该列起，左孩子右缘 =
  -- 该列−1（1 列 divider）→ nvim 右缘 77、右邻起 78。旧判定
  -- |nvim右缘−boundary|≤1 会算 |77−78.4|=1.4 把真实横向 split 排除，
  -- 误报「上下布局/独占 tab」
  local real_layout = {
    zoomed = false,
    panes = {
      { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 77, height = 61 } },
      { pane_id = "p-agent", rect = { x = 78, y = 0, width = 167, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
    },
  }
  local rl_exec, rl_log = mk_layout_fake(st_panes, real_layout, "t2", "p-nvim")
  utils.set_exec(rl_exec)
  panes.shrink_toggle("opencode")
  st_calls = resize_calls(rl_log)
  check(
    #st_calls == 1
      and st_calls[1]["--pane"] == "p-nvim"
      and st_calls[1]["--direction"] == "right"
      and st_calls[1]["--amount"] == "0.2300",
    "宽度 toggle：真实布局（边界 78.4，nvim 右缘 77）识别横向 split 并恢复 0.55"
  )

  -- 同 tab 后续形态（右侧 pane 再 split 出第二个 pane）：root 边界不变
  -- （78.4），nvim 归属仍是 root split；嵌套 split_1_1（边界 161.5）不参与
  -- nvim 的归属判定
  local grown_layout = {
    zoomed = false,
    panes = {
      { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 77, height = 61 } },
      { pane_id = "p-agent", rect = { x = 78, y = 0, width = 83, height = 61 } },
      { pane_id = "p-agent2", rect = { x = 162, y = 0, width = 83, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
      { id = "split_1_1", direction = "right", ratio = 0.5, rect = { x = 78, y = 0, width = 167, height = 61 } },
    },
  }
  local gr_exec, gr_log = mk_layout_fake(st_panes, grown_layout, "t2", "p-nvim")
  utils.set_exec(gr_exec)
  panes.shrink_toggle("opencode")
  st_calls = resize_calls(gr_log)
  check(
    #st_calls == 1
      and st_calls[1]["--pane"] == "p-nvim"
      and st_calls[1]["--direction"] == "right"
      and st_calls[1]["--amount"] == "0.2300",
    "宽度 toggle：右侧再 split 出新 pane 后仍调 root 边界（嵌套 split 不参与）"
  )

  -- 真实取整语义（默认比例 0.55）：边界 134.75 → round 135，nvim 右缘 134、
  -- agent 起 135。首按收窄：推 agent 向左吃进，amount = 0.55−0.32
  local rs_layout = {
    zoomed = false,
    panes = {
      { pane_id = "p-nvim", rect = { x = 0, y = 0, width = 134, height = 61 } },
      { pane_id = "p-agent", rect = { x = 135, y = 0, width = 110, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = 0.55, rect = { x = 0, y = 0, width = 245, height = 61 } },
    },
  }
  local rs_exec, rs_log = mk_layout_fake(st_panes, rs_layout, "t2", "p-nvim")
  utils.set_exec(rs_exec)
  panes.shrink_toggle("opencode")
  st_calls = resize_calls(rs_log)
  check(
    #st_calls == 1
      and st_calls[1]["--pane"] == "p-agent"
      and st_calls[1]["--direction"] == "left"
      and st_calls[1]["--amount"] == "0.2300",
    "宽度 toggle：真实取整语义（边界 134.75）首按收窄（agent 吃进）"
  )

  -- 真实取整语义镜像（nvim 是右孩子）：边界 78.4 → round 78 = nvim x，左邻
  -- 右缘 77。share = 1−0.32 = 0.68 → 收窄到 0.32：推左邻向右，amount = 0.36
  local rm_layout = {
    zoomed = false,
    panes = {
      { pane_id = "p-agent", rect = { x = 0, y = 0, width = 77, height = 61 } },
      { pane_id = "p-nvim", rect = { x = 78, y = 0, width = 167, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = 0.32, rect = { x = 0, y = 0, width = 245, height = 61 } },
    },
  }
  local rm_exec, rm_log = mk_layout_fake(st_panes, rm_layout, "t2", "p-nvim")
  utils.set_exec(rm_exec)
  panes.shrink_toggle("opencode")
  st_calls = resize_calls(rm_log)
  check(
    #st_calls == 1
      and st_calls[1]["--pane"] == "p-agent"
      and st_calls[1]["--direction"] == "right"
      and st_calls[1]["--amount"] == "0.3600",
    "宽度 toggle：真实取整语义镜像（nvim 右孩子，边界 78.4 = nvim x）收窄"
  )

  -- 真实取整语义嵌套：root 边界 98（p-left 右缘 97），嵌套 split_1 边界
  -- 171.5 → round 172 = nvim x（p-mid 右缘 171）。nvim 只匹配 split_1（root
  -- 边界 98 离 nvim 很远），share = 1−0.5 = 0.5 → 收窄：推 p-mid 向右，
  -- amount = 0.68−0.5 = 0.18
  local rn_layout = {
    zoomed = false,
    panes = {
      { pane_id = "p-left", rect = { x = 0, y = 0, width = 97, height = 61 } },
      { pane_id = "p-mid", rect = { x = 98, y = 0, width = 73, height = 61 } },
      { pane_id = "p-nvim", rect = { x = 172, y = 0, width = 73, height = 61 } },
    },
    splits = {
      { id = "split_0_root", direction = "right", ratio = 0.4, rect = { x = 0, y = 0, width = 245, height = 61 } },
      { id = "split_1", direction = "right", ratio = 0.5, rect = { x = 98, y = 0, width = 147, height = 61 } },
    },
  }
  local rn_exec, rn_log = mk_layout_fake(st_panes, rn_layout, "t2", "p-nvim")
  utils.set_exec(rn_exec)
  panes.shrink_toggle("opencode")
  st_calls = resize_calls(rn_log)
  check(
    #st_calls == 1
      and st_calls[1]["--pane"] == "p-mid"
      and st_calls[1]["--direction"] == "right"
      and st_calls[1]["--amount"] == "0.1800",
    "宽度 toggle：真实取整语义嵌套（取内层 split_1 边界，非 root）"
  )
end
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
local cl_exec, cl_log =
  mk_layout_fake(st_panes, divider_layout(134, 110), "t2", "p-nvim", { changed = true, layout = clamped_layout })
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

-- ---------------------------------------------------------------------------
-- skill 补全获取层（skills.lua，配置驱动）：fs 模式（user/project 目录 +
-- SKILL.md frontmatter，project_up 向上到 git 根）与 api 模式（CLI JSON 列表），
-- 按工具 + cwd 分键缓存；completion/skills.lua 仅是 blink 适配层，按当前工具取数
-- （包进局部函数：函数作用域独立计数，避免主 chunk 超出 200 局部上限）
-- ---------------------------------------------------------------------------
local function run_skill_tests()
  local skills = require("herder-agents.skills")

  -- fixture：用户级目录 / 假仓库（.git 平铺目录）/ 嵌套 cwd（sub/）/ 无 .git 的 plain/
  local base = "/tmp/opencode/herder-skills"
  local function write_skill(dir, fm_name, fm_desc)
    vim.fn.mkdir(dir, "p")
    local lines
    if fm_name then
      lines = { "---", "name: " .. fm_name, "description: " .. fm_desc, "---", "", "Body." }
    else
      lines = { "No frontmatter here." } -- 无 frontmatter：id 回落目录名
    end
    vim.fn.writefile(lines, dir .. "/SKILL.md")
  end
  local user_dir = base .. "/user-skills"
  write_skill(user_dir .. "/alpha", "alpha", "user alpha")
  write_skill(user_dir .. "/bare", nil)
  write_skill(user_dir .. "/dup", "dup", "user dup") -- 用户级 dup：应压过项目级
  local repo = base .. "/repo"
  vim.fn.mkdir(repo .. "/.git", "p") -- 假仓库（.git 平铺目录）
  write_skill(repo .. "/.agents/skills/dup", "dup", "ancestor dup")
  local sub = repo .. "/sub"
  write_skill(sub .. "/.pi/skills/deep", "deep", "deep pi")
  write_skill(sub .. "/.agents/skills/dup", "dup", "cwd dup")
  local plain = base .. "/plain" -- 无 .git：向上应走到文件系统根
  write_skill(plain .. "/.pi/skills/plain", nil)

  -- 真实脚本 fixture（端到端走 sh -c exec + 临时文件 + 读回 + 清理全链路）：
  -- 大载荷 ~600KB（贴近现场 65 技能 / 548KB），'b' 无尾换行保证 stdout 与
  -- JSON 逐字节一致
  local real_payload = base .. "/real-payload.json"
  vim.fn.writefile({
    vim.json.encode({
      data = { { id = "real", name = "Real Skill", description = string.rep("r", 600000), path = "/p/real" } },
    }),
  }, real_payload, "b")
  vim.fn.writefile({ "#!/bin/sh", 'exec cat "' .. real_payload .. '"', "" }, base .. "/fake-echo-cli.sh")
  vim.fn.setfperm(base .. "/fake-echo-cli.sh", "rwxr-xr-x")
  -- 失败脚本（非零退出）与慢脚本（超时 SIGKILL 用；脚本侧计数文件验证重复执行）
  vim.fn.writefile({ "#!/bin/sh", "exit 1", "" }, base .. "/fake-fail-cli.sh")
  vim.fn.setfperm(base .. "/fake-fail-cli.sh", "rwxr-xr-x")
  local slow_counter = base .. "/slow-counter"
  os.remove(slow_counter)
  vim.fn.writefile({
    "#!/bin/sh",
    'echo x >> "' .. slow_counter .. '"',
    "sleep 5",
    "printf '%s' '{\"data\":[]}'",
    "",
  }, base .. "/fake-slow-cli.sh")
  vim.fn.setfperm(base .. "/fake-slow-cli.sh", "rwxr-xr-x")

  -- 注册测试工具：myfs（带用户目录，user dup 胜出）/ myfs2（无用户目录，
  -- 祖先 dup 胜出）/ myapi1+myapi2（api 模式的两种响应形状）/
  -- myapi3（api+fs 共存：截断回退）/ myapi4（合法大响应）
  local saved_cwd = vim.fn.getcwd()
  local saved_tool = vim.g.ai_tool
  plugin.setup({
    tools = {
      myfs = {
        skills = {
          user = { user_dir },
          project = { ".pi/skills", ".agents/skills" },
          project_up = true,
          trigger = "/",
          label_prefix = "skill:",
        },
      },
      myfs2 = { skills = { project = { ".pi/skills", ".agents/skills" }, project_up = true, trigger = "/" } },
      myapi1 = { skills = { api = { "fake-skill-cli-1", "list" } } },
      myapi2 = { skills = { api = { "fake-skill-cli-2", "list" } } },
      myapi3 = {
        skills = {
          api = { "fake-skill-cli-3", "list" },
          user = { user_dir },
          project = { ".pi/skills" },
          project_up = true,
        },
      },
      myapi4 = { skills = { api = { "fake-skill-cli-4", "list" } } },
      myreal = { skills = { api = { base .. "/fake-echo-cli.sh" } } },
      myfail = { skills = { api = { base .. "/fake-fail-cli.sh" } } },
      myslow = { skills = { api = { base .. "/fake-slow-cli.sh" }, user = { user_dir } } },
    },
  })
  skills._reset()

  -- spec / trigger / triggers
  check(skills.spec("myfs") ~= nil and skills.spec("crush") == nil, "skills.spec：配置返回表，未配置 nil")
  check(skills.trigger("myfs") == "/" and skills.trigger("crush") == "@", "trigger：默认 @，配置覆盖为 /")
  check(
    vim.tbl_contains(skills.spec("qodercli").user, "~/.agents/skills")
      and vim.tbl_contains(skills.spec("qodercli").user, "~/.qoder/skills"),
    "qodercli 默认 user 目录含 ~/.agents/skills 与 ~/.qoder/skills"
  )
  local trigs = skills.triggers()
  check(
    vim.tbl_contains(trigs, "@") and vim.tbl_contains(trigs, "/"),
    "triggers：各工具触发字符的去重并集"
  )

  local function ids_of(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do
      out[e.id] = true
    end
    return out
  end

  -- fs 模式：嵌套 cwd（repo/sub）向上到假仓库根，user > 祖先 > cwd（first-discovered-wins）
  vim.cmd("cd " .. sub)
  local fs_entries
  skills.list("myfs", function(entries)
    fs_entries = entries
  end)
  local myfs_ids = ids_of(fs_entries)
  check(
    myfs_ids.alpha and myfs_ids.bare and myfs_ids.deep and myfs_ids.dup and #fs_entries == 4,
    "fs 列表：user 目录 + 上下两层 project 均发现，同 id 去重（dup 只留一份）"
  )
  for _, e in ipairs(fs_entries) do
    if e.id == "dup" then
      check(e.description == "user dup", "fs 优先级：user 级 dup 压过祖先/cwd 级（first-discovered-wins）")
    end
    if e.id == "bare" then
      check(
        e.name == "bare" and e.path:find("/bare/SKILL.md$", 1, false) ~= nil,
        "fs 解析：无 frontmatter 时 id/name 回落目录名"
      )
    end
    if e.id == "alpha" then
      check(e.description == "user alpha", "fs 解析：SKILL.md frontmatter 的 description 生效")
    end
  end
  check(
    fs_entries[1].id == "alpha"
      and fs_entries[2].id == "bare"
      and fs_entries[3].id == "dup"
      and fs_entries[4].id == "deep",
    "fs 列表：扫描顺序确定（user 层排序在前，project 层按根序追加）"
  )

  -- myfs2（无 user 目录）：祖先层 dup 压过 cwd 层；嵌套 cwd 两层都发现
  local fs2_entries
  skills.list("myfs2", function(entries)
    fs2_entries = entries
  end)
  for _, e in ipairs(fs2_entries) do
    if e.id == "dup" then
      check(e.description == "ancestor dup", "fs 优先级：无 user 时祖先层 dup 压过 cwd 层")
    end
  end
  local fs2_ids = ids_of(fs2_entries)
  check(
    fs2_ids.deep and fs2_ids.dup,
    "upwalk 边界：嵌套 cwd 发现 cwd 层（sub/.pi/skills）与祖先层（repo/.agents/skills）"
  )

  -- 无 .git 的目录：向上走到文件系统根，cwd 层的 skill 仍被发现、不报错
  vim.cmd("cd " .. plain)
  local plain_entries
  skills.list("myfs2", function(entries)
    plain_entries = entries
  end)
  check(ids_of(plain_entries).plain, "upwalk 边界：无 .git（走到文件系统根）仍发现 cwd 层 skill")

  -- api 模式：两种响应形状归一化 + 缓存（新鲜期内第二次 list 不再 exec）
  vim.cmd("cd " .. saved_cwd)
  local api_calls = {}
  local cli3_calls = 0
  -- 截断响应 fixture：合法 JSON（含 70KB description）在 64KiB 处切断
  local truncated_json = vim.json
    .encode({
      data = { { id = "huge", name = "Huge", description = string.rep("x", 70000), path = "/p/huge" } },
    })
    :sub(1, 65536)
  -- 注入临时文件中转执行器（api_fetch 现走 exec_async_to_file）：假执行器契约
  -- 相同 {code, stdout, stderr}，忽略 timeout_ms；保存引用供真实链路测试后回装
  local skill_fake = function(argv, on_done)
    table.insert(api_calls, argv[1])
    if argv[1] == "fake-skill-cli-1" then
      on_done({
        code = 0,
        stdout = vim.json.encode({
          data = { { id = "alpha", name = "Alpha Skill", description = "api desc", path = "/p/alpha" } },
        }),
        stderr = "",
      })
    elseif argv[1] == "fake-skill-cli-2" then
      on_done({
        code = 0,
        stdout = vim.json.encode({ data = { { name = "beta", location = "/p/beta", description = "loc desc" } } }),
        stderr = "",
      })
    elseif argv[1] == "fake-skill-cli-3" then
      -- 复现现场 bug：CLI 经管道偶发截断大响应（退出码仍 0，JSON 被切在
      -- 字符串字面量中间 → 不完整），64KiB 边界与报告一致
      cli3_calls = cli3_calls + 1
      on_done({ code = 0, stdout = truncated_json, stderr = "" })
    elseif argv[1] == "fake-skill-cli-4" then
      -- 合法大响应（~600KB，贴近现场 65 技能 / 548KB）：大体积本身不是失败原因
      on_done({
        code = 0,
        stdout = vim.json.encode({ data = { { id = "big", description = string.rep("y", 600000), path = "/p/big" } } }),
        stderr = "",
      })
    else
      on_done({ code = 0, stdout = "", stderr = "" })
    end
  end
  utils.set_exec_to_file(skill_fake)
  skills._reset()
  local api1
  skills.list("myapi1", function(entries)
    api1 = entries
  end)
  check(
    api1
      and api1[1]
      and api1[1].id == "alpha"
      and api1[1].name == "Alpha Skill"
      and api1[1].description == "api desc"
      and api1[1].path == "/p/alpha",
    "api 模式：{id,...} 形状归一化"
  )
  local api2
  skills.list("myapi2", function(entries)
    api2 = entries
  end)
  check(
    api2 and api2[1] and api2[1].id == "beta" and api2[1].name == "beta" and api2[1].path == "/p/beta",
    "api 模式：{name,location} 形状归一化（id/name、path/location 兼容）"
  )
  skills.list("myapi1", function() end)
  check(#vim.tbl_filter(function(c)
    return c == "fake-skill-cli-1"
  end, api_calls) == 1, "缓存：新鲜期内第二次 list 不再执行 CLI")
  local none
  skills.list("crush", function(entries)
    none = entries
  end)
  check(none ~= nil and #none == 0, "未配置 skills 的工具：list 回 {}（无 skill 补全）")

  -- api + fs 共存（myapi3）：截断响应（退出码 0、JSON 不完整）→ 自动回退目录
  -- 扫描 + 每会话每工具告警一次；回退结果进缓存，期内第二次 list 不再 exec/告警。
  -- myapi4：合法大响应（~600KB）照常从 api 解析（大体积 ≠ 失败）
  local saved_warn = utils.warn
  local warn_log = {}
  utils.warn = function(msg)
    table.insert(warn_log, tostring(msg))
  end
  vim.cmd("cd " .. sub)
  skills._reset()
  local api3
  skills.list("myapi3", function(entries)
    api3 = entries
  end)
  local api3_ids = ids_of(api3)
  check(
    api3_ids.alpha and api3_ids.bare and api3_ids.dup and api3_ids.deep,
    "api 失败回退：截断响应（退出码 0）自动回落目录扫描（user + project 均生效）"
  )
  check(
    #warn_log == 1
      and warn_log[1]:find("myapi3", 1, true) ~= nil
      and warn_log[1]:find("已回退目录扫描", 1, true) ~= nil,
    "api 失败告警：每工具只提示一次，说明截断原因与回退后果"
  )
  skills.list("myapi3", function() end)
  check(
    #vim.tbl_filter(function(c)
      return c == "fake-skill-cli-3"
    end, api_calls) == 1 and #warn_log == 1,
    "api 失败回退：结果进缓存，期内第二次 list 不再 exec 也不再告警"
  )
  local api4
  skills.list("myapi4", function(entries)
    api4 = entries
  end)
  check(
    api4 and api4[1] and api4[1].id == "big" and #api4[1].description == 600000 and api4[1].path == "/p/big",
    "api 大响应：合法的 ~600KB 输出照常解析（无 fs 字段）"
  )
  check(#warn_log == 1, "api 大响应：成功不触发告警")

  -- ---------------------------------------------------------------------------
  -- 真实执行器路径（撤掉注入假执行器）：临时文件中转全链路 + 残留/超时断言。
  -- TMPDIR 指到 fixture tmpdir —— vim.fn.tempname 在调用时取 $TMPDIR（已实测），
  -- 残留 = tmpdir 下任何 *.json 文件（tempname 建的 nvim.<user>/XXXX 会话目录
  -- 与其内部的非 .json 文件是 vim 自身会话临时区，不属于本层残留）
  -- ---------------------------------------------------------------------------
  utils.set_exec_to_file(nil)
  local saved_tmpdir = vim.env.TMPDIR
  local tmpdir = base .. "/tmpdir"
  vim.fn.mkdir(tmpdir, "p")
  vim.fn.setenv("TMPDIR", tmpdir)
  check(vim.fn.tempname():find(tmpdir, 1, true) == 1, "tempname 遵循调用时的 $TMPDIR（残留断言前提）")
  local function json_residue(dir, out, depth)
    if depth > 6 then
      return
    end
    local ok, names = pcall(vim.fn.readdir, dir)
    if not ok or type(names) ~= "table" then
      return
    end
    for _, name in ipairs(names) do
      local p = dir .. "/" .. name
      if name:find(".json", 1, true) then -- 命中 "<x>.json" 与 "<x>.json.err" 两种中转文件
        table.insert(out, p)
      elseif vim.fn.isdirectory(p) == 1 then
        json_residue(p, out, depth + 1)
      end
    end
  end
  local residue = function()
    local out = {}
    json_residue(tmpdir, out, 0)
    return out
  end
  check(#residue() == 0, "残留基线：tmpdir 初始无 *.json")

  -- 成功路径：真实脚本经 sh -c exec + 唯一临时文件读回 600KB JSON
  skills._reset()
  local real_entries
  skills.list("myreal", function(entries)
    real_entries = entries
  end)
  check(
    vim.wait(5000, function()
      return real_entries ~= nil
    end, 10),
    "临时文件中转：真实 CLI 异步完成（事件循环等待回调）"
  )
  check(
    real_entries and real_entries[1] and real_entries[1].id == "real" and #real_entries[1].description == 600000,
    "临时文件中转：600KB 响应完整读回并解析（文件重定向无管道截断）"
  )
  check(#residue() == 0, "残留断言：成功路径零残留（临时文件已删除）")

  -- 失败路径：非零退出 → {}（无 fs 字段不回退），仍零残留
  local fail_entries
  skills.list("myfail", function(entries)
    fail_entries = entries
  end)
  vim.wait(5000, function()
    return fail_entries ~= nil
  end, 10)
  check(fail_entries ~= nil and #fail_entries == 0, "失败脚本：非零退出回 {}（无 fs 字段不回退）")
  check(#residue() == 0, "残留断言：非零退出路径零残留")

  -- 超时路径：150ms SIGKILL（脚本 sleep 5）→ 回退 fs；in_flight 已清（第二次
  -- list 重新执行，脚本侧计数 +1）；全程不等满 5s
  skills._api_timeout_ms = 150
  skills._reset()
  local t0 = vim.uv.now()
  local slow1
  skills.list("myslow", function(entries)
    slow1 = entries
  end)
  vim.wait(10000, function()
    return slow1 ~= nil
  end, 5)
  local elapsed = vim.uv.now() - t0
  local slow1_ids = ids_of(slow1)
  check(
    slow1_ids.alpha and slow1_ids.bare and slow1_ids.dup and #slow1 == 3,
    "超时回退：SIGKILL 后回落目录扫描（user 层 3 条）"
  )
  check(elapsed < 3000, ("超时生效：~%dms 返回（SIGKILL 命中，未等满 5s sleep）"):format(elapsed))
  check(#residue() == 0, "残留断言：超时路径零残留")
  -- 回退结果已进缓存（与 myapi3 同款行为）：立即二次 list 走缓存同步回调，
  -- 不重复执行 CLI（脚本计数不变），也证明回调投递无死锁
  local slow2
  skills.list("myslow", function(entries)
    slow2 = entries
  end)
  local ok_cnt, cnt = pcall(vim.fn.readfile, slow_counter)
  check(
    slow2 ~= nil and #slow2 == 3 and ok_cnt and #cnt == 1,
    "超时路径：二次 list 走缓存的回退结果（同步回调，不重复 exec）"
  )
  -- reset 后再 list：超时拉取后链路完全可复用，重新执行 CLI（脚本计数 +1）
  skills._reset()
  local slow3
  skills.list("myslow", function(entries)
    slow3 = entries
  end)
  vim.wait(10000, function()
    return slow3 ~= nil
  end, 5)
  ok_cnt, cnt = pcall(vim.fn.readfile, slow_counter)
  check(
    slow3 ~= nil and #slow3 == 3 and ok_cnt and #cnt >= 2,
    "超时路径：in_flight 已清，reset 后再 list 重新执行 CLI（脚本计数 ≥2）"
  )
  check(#residue() == 0, "残留断言：超时 + 重复拉取零残留")

  -- 还原 TMPDIR / 超时 / 假执行器（适配层测试还要用）/ 告警
  if saved_tmpdir then
    vim.env.TMPDIR = saved_tmpdir
  else
    vim.env.TMPDIR = nil
  end
  skills._api_timeout_ms = 10000
  utils.set_exec_to_file(skill_fake)
  utils.warn = saved_warn

  -- blink 适配层（completion/skills.lua）：按当前工具取数、label 前缀、触发字符判定
  local adapter = require("herder-agents.completion.skills")
  local source = adapter.new({})
  check(
    vim.tbl_contains(source:get_trigger_characters(), "/") and vim.tbl_contains(source:get_trigger_characters(), "@"),
    "适配层：get_trigger_characters 返回触发字符并集"
  )
  skills._reset()
  vim.g.ai_tool = "myfs"
  vim.cmd("cd " .. sub)
  local slash_items
  source:get_completions({ line = "/al", keyword = "al", cursor = { 0, 3 } }, function(res)
    slash_items = res.items
  end)
  local slash_labels = {}
  for _, it in ipairs(slash_items or {}) do
    table.insert(slash_labels, it.label)
  end
  check(
    vim.tbl_contains(slash_labels, "skill:alpha") and vim.tbl_contains(slash_labels, "skill:deep"),
    "适配层：/ 触发（myfs）label 带 label_prefix（skill:<id>）"
  )
  for _, it in ipairs(slash_items or {}) do
    if it.label == "skill:alpha" then
      check(it.detail == "skill: user alpha", "适配层：detail = skill: <description>")
    end
  end
  -- 触发字符不匹配（myfs 是 "/"，输入的是 "@"）→ 空
  local mismatch
  source:get_completions({ line = "@al", keyword = "al", cursor = { 0, 3 } }, function(res)
    mismatch = res.items
  end)
  check(mismatch ~= nil and #mismatch == 0, "适配层：触发字符与当前工具配置不符时回空")
  -- "@" 触发（myapi1，无 label_prefix）
  vim.g.ai_tool = "myapi1"
  local at_items
  source:get_completions({ line = "@al", keyword = "al", cursor = { 0, 3 } }, function(res)
    at_items = res.items
  end)
  check(
    at_items ~= nil and #at_items == 1 and at_items[1].label == "alpha",
    "适配层：@ 触发 label 即 id（无前缀）"
  )

  -- 还原：执行器注入、超时、cwd、当前工具、测试工具与 skill 缓存
  utils.set_exec(nil)
  utils.set_exec_to_file(nil)
  utils.set_exec_async(nil)
  skills._reset()
  skills._api_timeout_ms = 10000
  vim.cmd("cd " .. saved_cwd)
  vim.g.ai_tool = saved_tool
  for _, name in ipairs({ "myfs", "myfs2", "myapi1", "myapi2", "myapi3", "myapi4", "myreal", "myfail", "myslow" }) do
    cfg.options.tools[name] = nil
  end
  cfg.options.tool_order = vim.tbl_filter(function(n)
    return cfg.options.tools[n] ~= nil
  end, cfg.options.tool_order)
end
run_skill_tests()

-- 恢复真实执行器
utils.set_exec(nil)
utils.set_exec_to_file(nil)
utils.set_exec_async(nil)
delivery._reset()

-- ---------------------------------------------------------------------------
-- agent 提问表单（llm.lua + question.lua，ADR-0002）：全 headless、假执行器；
-- ui/question_form.lua 由并行 lane 实现 —— 这里用 package.preload stub。
-- ---------------------------------------------------------------------------
local function run_question_tests()
local llm = require("herder-agents.llm")
local question_mod = require("herder-agents.question")

-- question_form stub：按 UI 契约实现 open_loading 句柄 —— 记录 open_loading()
-- 调用次数 / set_stage 阶段序列 / morph_to(spec) 列表；closed 句柄上
-- set_stage / morph_to 均 no-op；测试直接置 handle.closed = true 模拟 esc 取消
local form_specs, form_submit = {}, nil
local loading_calls, stage_log, loading_handles = 0, {}, {}
package.preload["herder-agents.ui.question_form"] = function()
  return {
    open_loading = function()
      loading_calls = loading_calls + 1
      local handle = { closed = false }
      table.insert(loading_handles, handle)
      function handle.set_stage(stage, detail)
        if handle.closed then
          return
        end
        table.insert(stage_log, { stage = stage, detail = detail })
      end
      function handle.morph_to(spec, on_submit)
        if handle.closed then
          return
        end
        table.insert(form_specs, spec)
        form_submit = on_submit
      end
      function handle.close()
        handle.closed = true
      end
      return handle
    end,
  }
end

-- 命令注册与 llm 默认配置
check(vim.api.nvim_get_commands({}).AIQuestion ~= nil, ":AIQuestion 命令已注册")
check(
  cfg.options.llm.base_url == "https://api.deepseek.com"
    and cfg.options.llm.api_key_env == "DEEPSEEK_API_KEY"
    and cfg.options.llm.model == "deepseek-chat",
  "llm 默认 base_url / api_key_env / model（DeepSeek 开箱）"
)
check(
  cfg.options.llm.timeout_ms == 30000 and cfg.options.llm.temperature == 0,
  "llm 默认 timeout_ms=30000 / temperature=0"
)
check(
  cfg.options.llm.start_lines == 80
    and cfg.options.llm.max_read_more == 2
    and cfg.options.llm.retries == 1,
  "llm 默认 start_lines=80 / max_read_more=2 / retries=1"
)
check(cfg.options.llm.enabled == true and cfg.options.llm.hint == true, "llm 默认 enabled/hint 开启")
check(
  type(cfg.options.question_form) == "table" and cfg.options.question_form.height_ratio == 0.6,
  "question_form.height_ratio 默认 0.6（弹窗固定高度 = 编辑器行数 × ratio）"
)

local qa_saved_llm = vim.deepcopy(cfg.options.llm)
local qa_saved_tool = vim.g.ai_tool
local qa_saved_key = vim.env.DEEPSEEK_API_KEY

-- llm.ask：假 curl（模拟 exec_async_to_file：响应写临时输出文件再读回）→ 正常 JSON 解码
vim.env.DEEPSEEK_API_KEY = "test-key"
local to_file_calls = {}
utils.set_exec_to_file(function(argv, on_done, timeout_ms)
  table.insert(to_file_calls, { argv = argv, timeout_ms = timeout_ms })
  local f = vim.fn.tempname() .. ".json"
  vim.fn.writefile(
    { vim.json.encode({ choices = { { message = { content = vim.json.encode({ hello = "world" }) } } } }) },
    f
  )
  local out = table.concat(vim.fn.readfile(f), "\n")
  os.remove(f)
  on_done({ code = 0, stdout = out, stderr = "" })
end)
local ask_obj, ask_err
llm.ask({ system = "sys", user = "usr", timeout_ms = 15000 }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(ask_obj ~= nil and ask_err == nil and ask_obj.hello == "world", "llm.ask 成功解码 choices[1].message.content")
local qcall = to_file_calls[1]
check(qcall ~= nil and qcall.argv[1] == "curl", "内置实现经 curl（exec_async_to_file 通道）")
check(qcall.timeout_ms == 15000, "timeout_ms 透传 exec_async_to_file（SIGKILL 兜底）")
local qjoined = table.concat(qcall.argv, " ")
check(qjoined:find("/chat/completions", 1, true) ~= nil, "请求 OpenAI 兼容 /chat/completions")
check(qjoined:find("Authorization: Bearer test-key", 1, true) ~= nil, "携带 Authorization header")
check(
  qjoined:find("response_format", 1, true) ~= nil and qjoined:find("json_object", 1, true) ~= nil,
  "body 含 response_format=json_object"
)
check(vim.tbl_contains(qcall.argv, "-m") and vim.tbl_contains(qcall.argv, "15"), "curl -m 应用层超时（秒）")

-- llm.ask 失败面：curl 非零 / HTTP 坏 JSON / content 坏 JSON
utils.set_exec_to_file(function(argv, on_done)
  on_done({ code = 7, stdout = "", stderr = "connection refused" })
end)
ask_obj, ask_err = nil, nil
llm.ask({ system = "s", user = "u" }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(
  ask_obj == nil and type(ask_err) == "string" and ask_err:find("connection refused", 1, true) ~= nil,
  "curl 非零退出 → nil + err"
)

utils.set_exec_to_file(function(argv, on_done)
  on_done({ code = 0, stdout = "not json at all", stderr = "" })
end)
ask_obj, ask_err = nil, nil
llm.ask({ system = "s", user = "u" }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(ask_obj == nil and type(ask_err) == "string", "HTTP 响应坏 JSON → nil + err")

utils.set_exec_to_file(function(argv, on_done)
  on_done({ code = 0, stdout = vim.json.encode({ choices = { { message = { content = "{oops" } } } }), stderr = "" })
end)
ask_obj, ask_err = nil, nil
llm.ask({ system = "s", user = "u" }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(ask_obj == nil and type(ask_err) == "string", "message.content 坏 JSON → nil + err")

-- 缺 api_key（内置通道）：nil + err 且不起子进程
local key_probe_calls = 0
utils.set_exec_to_file(function(argv, on_done)
  key_probe_calls = key_probe_calls + 1
  on_done({ code = 1, stdout = "", stderr = "" })
end)
vim.env.DEEPSEEK_API_KEY = nil
ask_obj, ask_err = nil, nil
llm.ask({ system = "s", user = "u" }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(
  ask_obj == nil and type(ask_err) == "string" and ask_err:find("DEEPSEEK_API_KEY", 1, true) ~= nil,
  "缺 api_key → nil + err（含 env 变量名）"
)
check(key_probe_calls == 0, "缺 api_key 不起子进程")
vim.env.DEEPSEEK_API_KEY = "test-key"

-- adapter 覆盖（仿 utils.set_exec 注入惯例）
llm.set_adapter(function(opts, cb)
  cb({ via = "adapter", user = opts.user }, nil)
end)
ask_obj, ask_err = nil, nil
llm.ask({ system = "s", user = "usr2" }, function(obj, err)
  ask_obj, ask_err = obj, err
end)
check(ask_obj ~= nil and ask_obj.via == "adapter" and ask_obj.user == "usr2", "set_adapter 覆盖内置实现")
llm.set_adapter(nil)

-- ---------------------------------------------------------------------------
-- llm 请求定制（extra_body / extra_headers / disable_thinking，仿 neogit ai_commit）
-- ---------------------------------------------------------------------------
check(
  cfg.options.llm.extra_body == nil
    and cfg.options.llm.extra_headers == nil
    and cfg.options.llm.disable_thinking == false,
  "llm 默认 extra_body/extra_headers=nil、disable_thinking=false"
)

local body_argv_calls = {}
local eb, hcount -- 复用的断言临时变量
utils.set_exec_to_file(function(argv, on_done)
  table.insert(body_argv_calls, argv)
  on_done({
    code = 0,
    stdout = vim.json.encode({ choices = { { message = { content = vim.json.encode({ ok = true }) } } } }),
    stderr = "",
  })
end)
-- 从 curl argv 的 -d 后继元素解出请求体（decode 断言用）
local function req_body(argv)
  for i, a in ipairs(argv) do
    if a == "-d" then
      return vim.json.decode(argv[i + 1])
    end
  end
end

-- extra_body 深合并进请求体（内置字段保留）
body_argv_calls = {}
cfg.options.llm.extra_body = { enable_thinking = false }
llm.ask({ system = "s", user = "u" }, function() end)
eb = req_body(body_argv_calls[1])
check(
  eb ~= nil and eb.enable_thinking == false and eb.temperature == 0 and eb.response_format.type == "json_object",
  "extra_body 深合并进 -d body（内置字段保留）"
)

-- extra_body 嵌套表深合并（vLLM 的 chat_template_kwargs）
body_argv_calls = {}
cfg.options.llm.extra_body = { chat_template_kwargs = { enable_thinking = false } }
llm.ask({ system = "s", user = "u" }, function() end)
eb = req_body(body_argv_calls[1])
check(
  eb ~= nil and type(eb.chat_template_kwargs) == "table" and eb.chat_template_kwargs.enable_thinking == false,
  "extra_body 嵌套表（chat_template_kwargs）深合并"
)

-- extra_body 覆盖内置字段（用户赢）
body_argv_calls = {}
cfg.options.llm.extra_body = { temperature = 0.2 }
llm.ask({ system = "s", user = "u" }, function() end)
eb = req_body(body_argv_calls[1])
check(eb ~= nil and eb.temperature == 0.2, "extra_body 覆盖内置字段（temperature=0.2）")
cfg.options.llm.extra_body = nil

-- disable_thinking 厂商预设：按 base_url 明文 needle 依序匹配
cfg.options.llm.disable_thinking = true
local preset_cases = {
  { base = "http://127.0.0.1:11434", probe = function(b) return b.think == false end },
  {
    base = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    probe = function(b) return b.enable_thinking == false end,
  },
  {
    base = "https://api.deepseek.com",
    probe = function(b) return type(b.thinking) == "table" and b.thinking.type == "disabled" end,
  },
  {
    base = "https://openrouter.ai/api/v1",
    probe = function(b) return type(b.reasoning) == "table" and b.reasoning.enabled == false end,
  },
  { base = "https://api.openai.com/v1", probe = function(b) return b.reasoning_effort == "minimal" end },
}
for _, pc in ipairs(preset_cases) do
  body_argv_calls = {}
  cfg.options.llm.base_url = pc.base
  llm.ask({ system = "s", user = "u" }, function() end)
  local pb = req_body(body_argv_calls[1])
  check(pb ~= nil and pc.probe(pb), "disable_thinking 预设注入：" .. pc.base)
end

-- 未知端点：不注入 + warn 一次（第二次调用不再 warn）
local warns = {}
local saved_warn = utils.warn
utils.warn = function(msg)
  table.insert(warns, msg)
end
body_argv_calls = {}
cfg.options.llm.base_url = "https://llm.example.com/v1"
llm.ask({ system = "s", user = "u" }, function() end)
local ub = req_body(body_argv_calls[1])
check(
  ub ~= nil
    and ub.think == nil
    and ub.enable_thinking == nil
    and ub.thinking == nil
    and ub.reasoning == nil
    and ub.reasoning_effort == nil
    and #warns == 1,
  "disable_thinking 未知端点 → 不注入字段 + warn 一次"
)
body_argv_calls = {}
llm.ask({ system = "s", user = "u" }, function() end)
check(#warns == 1, "未知端点 warn 每会话仅一次（第二次调用静默）")
utils.warn = saved_warn

-- extra_body 与预设同时存在 → extra_body 赢（覆盖预设）
body_argv_calls = {}
cfg.options.llm.base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
cfg.options.llm.extra_body = { enable_thinking = true }
llm.ask({ system = "s", user = "u" }, function() end)
eb = req_body(body_argv_calls[1])
check(eb ~= nil and eb.enable_thinking == true, "extra_body 与 disable_thinking 预设同时存在 → extra_body 赢")
cfg.options.llm.disable_thinking = false
cfg.options.llm.extra_body = nil
cfg.options.llm.base_url = "https://api.deepseek.com"

-- extra_headers 追加 HTTP 头（Authorization/Content-Type 之后）
body_argv_calls = {}
cfg.options.llm.extra_headers = { ["X-Tenant"] = "team-a", TTL = 30 }
llm.ask({ system = "s", user = "u" }, function() end)
hcount = 0
for _, a in ipairs(body_argv_calls[1]) do
  if a == "-H" then
    hcount = hcount + 1
  end
end
check(
  vim.tbl_contains(body_argv_calls[1], "X-Tenant: team-a")
    and vim.tbl_contains(body_argv_calls[1], "TTL: 30")
    and hcount == 4,
  "extra_headers 追加 -H \"k: v\"（数字值 tostring，含内置共 4 个）"
)
cfg.options.llm.extra_headers = nil

-- 未配置 extra_headers：仅 Authorization/Content-Type 两个 -H
body_argv_calls = {}
llm.ask({ system = "s", user = "u" }, function() end)
hcount = 0
for _, a in ipairs(body_argv_calls[1]) do
  if a == "-H" then
    hcount = hcount + 1
  end
end
check(hcount == 2, "未配置 extra_headers 时仅 Authorization/Content-Type 两个 -H")

-- ---------------------------------------------------------------------------
-- 编排（question.ask）：need_more 翻倍重读 / 失败重试 / fallback / 文本通道提交
-- ---------------------------------------------------------------------------
cfg.options.tools.qatool = { title = " QA Chat ", paste_wrap = true }
table.insert(cfg.options.tool_order, "qatool")
cfg.set_current_tool("qatool")

delivery._reset()
local read_log = {} -- 每次 `herdr agent read` 的 --lines 值
local read_pages = {} -- 按调用序弹出的捕获文本（空则默认文本）
local submitted = {} -- send-text / send-keys / agent prompt 记录
local qa_agents = { qa1 = "blocked" } -- 已注册且 blocked：提交必须强制文本通道
local qa_exec = function(argv)
  if argv[2] == "agent" and argv[3] == "read" then
    table.insert(read_log, tonumber(argv[6]))
    return { code = 0, stdout = (table.remove(read_pages, 1) or "agent asks: pick one? [1] yes [2] no"), stderr = "" }
  end
  if argv[2] == "agent" and argv[3] == "prompt" then
    table.insert(submitted, { kind = "prompt", payload = argv[5] })
    return { code = 0, stdout = "", stderr = "" }
  end
  if argv[2] == "agent" and argv[3] == "list" then
    local agents = {}
    for pid, st in pairs(qa_agents) do
      table.insert(agents, { pane_id = pid, agent = "qa", agent_status = st, cwd = "/tmp" })
    end
    return { code = 0, stdout = vim.json.encode({ result = { agents = agents } }) }
  end
  if argv[2] == "pane" and argv[3] == "current" then
    return { code = 0, stdout = vim.json.encode({ result = { pane = { tab_id = "tq" } } }) }
  end
  if argv[2] == "pane" and argv[3] == "list" then
    return {
      code = 0,
      stdout = vim.json.encode({ result = { panes = { { label = "qatool", tab_id = "tq", pane_id = "qa1" } } } }),
    }
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
  if argv[3] == "send-text" then
    table.insert(submitted, { kind = "text", payload = argv[5] })
    return { code = 0, stdout = "", stderr = "" }
  end
  if argv[3] == "send-keys" then
    table.insert(submitted, { kind = "key", key = argv[5] })
    return { code = 0, stdout = "", stderr = "" }
  end
  return { code = 0, stdout = "", stderr = "" }
end
utils.set_exec(qa_exec)
utils.set_exec_async(function(argv, on_done)
  on_done({ code = 0, stdout = "", stderr = "" })
end)

-- 编排用 adapter：按脚本回放（string = 模拟失败，table = 已解码的提取 JSON）
local adapter_log = {}
local script = {}
local script_adapter = function(opts, cb)
  table.insert(adapter_log, { system = opts.system, user = opts.user })
  local r = table.remove(script, 1)
  if type(r) == "string" then
    cb(nil, r)
    return
  end
  cb(r, nil)
end
llm.set_adapter(script_adapter)

-- 1) 多问题提取：need_more → 行数翻倍重读 → 2 题 complete 出 form 表单
script = {
  { status = "need_more" },
  {
    status = "complete",
    questions = {
      { question = "Proceed?", options = { "yes", "no" }, multiple = false, suggested = { 1 } },
      { question = "Pick a model?", options = { "glm-5", "glm-4" }, multiple = true, suggested = {} },
    },
  },
}
form_specs = {}
read_log = {}
question_mod.ask()
check(#read_log == 2 and read_log[1] == 80 and read_log[2] == 160, "need_more → --lines 翻倍重读（80 → 160）")
-- system_prompt 语义（原始内容仍是唯一事实源）：编号进 label、question 不含自身
-- 编号前缀、其余 verbatim 复制 —— 字符串断言（含 verbatim 措辞与编号前缀措辞）
local qsys = adapter_log[1] and adapter_log[1].system or ""
check(
  qsys:find("copied verbatim", 1, true) ~= nil
    and qsys:find("Never invent questions or options", 1, true) ~= nil
    and qsys:find("never remove, rewrite, or renumber", 1, true) ~= nil
    and qsys:find("WITHOUT its own numbering prefix", 1, true) ~= nil
    and qsys:find("must NOT contain the option", 1, true) ~= nil
    and qsys:find("MAY use markdown syntax", 1, true) ~= nil
    and qsys:find("KEEP each option's original label prefix", 1, true) ~= nil
    and qsys:find("purely mechanical FORMAT CONVERSION", 1, true) ~= nil
    and qsys:find("do NOT analyze", 1, true) ~= nil
    and qsys:find("strip", 1, true) == nil
    and qsys:find("the form numbers questions", 1, true) == nil,
  "system_prompt 逐字语义 + question 不含自身编号前缀（编号进 label）+ 不含选项文本"
)
check(#form_specs == 1 and form_specs[1].mode == "form", "complete → form 表单")
check(
  type(form_specs[1].questions) == "table"
    and #form_specs[1].questions == 2
    and form_specs[1].question == nil,
  "morph spec 携带 questions[]（2 题；不再有旧顶层 question 字段）"
)
check(
  form_specs[1].questions[1].question == "Proceed?"
    and form_specs[1].questions[1].options[1] == "yes"
    and form_specs[1].questions[1].options[2] == "no",
  "morph spec 第 1 题逐字携带 question/options"
)
check(
  form_specs[1].questions[1].multiple == false and form_specs[1].questions[1].suggested[1] == 1,
  "morph spec 第 1 题携带 multiple/suggested"
)
check(
  form_specs[1].questions[2].question == "Pick a model?"
    and form_specs[1].questions[2].options[2] == "glm-4"
    and form_specs[1].questions[2].multiple == true
    and type(form_specs[1].questions[2].suggested) == "table"
    and #form_specs[1].questions[2].suggested == 0,
  "morph spec 第 2 题逐字携带 question/options/multiple/suggested（空数组保留）"
)

-- 1b) N=1 回归：单题 complete 的 morph spec 是 questions 长度 1（suggested 缺省归一为空数组）
script = {
  { status = "complete", questions = { { question = "Solo?", options = { "a" }, multiple = false } } },
}
form_specs = {}
question_mod.ask()
check(
  #form_specs == 1
    and form_specs[1].mode == "form"
    and type(form_specs[1].questions) == "table"
    and #form_specs[1].questions == 1
    and form_specs[1].questions[1].question == "Solo?"
    and form_specs[1].questions[1].options[1] == "a"
    and form_specs[1].questions[1].multiple == false
    and type(form_specs[1].questions[1].suggested) == "table"
    and #form_specs[1].questions[1].suggested == 0
    and form_specs[1].options == nil
    and form_specs[1].suggested == nil,
  "单题 complete → spec.questions 长度 1（每题字段齐全，无旧顶层字段）"
)

-- 1c) desc 字段（extraction schema v2 扩展）：system_prompt 携带 schema 与规则
-- 措辞；validate 逐字携带 / 缺省归一 ""；morph spec 每题携带 desc
script = {
  {
    status = "complete",
    questions = {
      {
        question = "Deploy how?",
        desc = "➡️ 推荐 (a)：Docker，环境一致、回滚方便",
        options = { "Docker", "bare metal" },
        multiple = false,
        suggested = { 1 },
      },
      { question = "No desc here?", options = { "yes", "no" }, multiple = true, suggested = {} },
    },
  },
}
form_specs = {}
adapter_log = {}
question_mod.ask()
local dsys = adapter_log[1] and adapter_log[1].system or ""
check(
  dsys:find('"desc": string', 1, true) ~= nil
    and dsys:find("ONLY the recommendation note", 1, true) ~= nil
    and dsys:find("NEVER contains option content", 1, true) ~= nil
    and dsys:find('use "" when', 1, true) ~= nil
    and dsys:find("Never invent questions or options", 1, true) ~= nil,
  "system_prompt 携带 desc schema 行与规则措辞（说明文本/不含选项文本/缺省空串）"
)
check(
  #form_specs == 1
    and form_specs[1].mode == "form"
    and form_specs[1].questions[1].desc == "➡️ 推荐 (a)：Docker，环境一致、回滚方便",
  "morph spec 第 1 题逐字携带 desc"
)
check(
  form_specs[1].questions[2].desc == "",
  "morph spec 缺省 desc 归一为空串（validate 缺省携带）"
)

-- 1d) desc 非 string → 整体无效 → 重试路径（失败原因附 desc 措辞），重试成功出 form
script = {
  { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false, desc = 42 } } },
  { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false } } },
}
form_specs = {}
adapter_log = {}
question_mod.ask()
check(
  #adapter_log == 2 and adapter_log[2].system:find("desc 必须是 string", 1, true) ~= nil,
  "desc 非 string → 整体无效并重试（失败原因附 questions[k] desc 必须是 string）"
)
check(
  form_specs[1] ~= nil
    and form_specs[1].mode == "form"
    and form_specs[1].questions[1].desc == "",
  "desc 无效重试成功 → form 表单（重试轮缺省 desc 归一空串）"
)

-- 1e) label 字段（原始标号元数据）：system_prompt 携带 schema 行与规则措辞
--（按原样复制标号 / 无标号归 ""）；validate 逐字携带 / 缺省归一 ""；
-- morph spec 每题携带 label（显示层不渲染，仅提交块头/拦截提示/输入标题用）
script = {
  {
    status = "complete",
    questions = {
      {
        label = "Q2",
        question = "Deploy how?",
        options = { "Docker", "bare metal" },
        multiple = false,
        suggested = { 1 },
      },
      { question = "No label here?", options = { "yes", "no" }, multiple = true, suggested = {} },
    },
  },
}
form_specs = {}
adapter_log = {}
question_mod.ask()
local lsys = adapter_log[1] and adapter_log[1].system or ""
check(
  lsys:find('"label": string', 1, true) ~= nil
    and lsys:find("the question's own number in the excerpt", 1, true) ~= nil
    and lsys:find('use "" when the question carries no number', 1, true) ~= nil
    and lsys:find("Never invent questions or options", 1, true) ~= nil,
  "system_prompt 携带 label schema 行与规则措辞（原样复制标号/无标号归空串）"
)
check(
  #form_specs == 1
    and form_specs[1].mode == "form"
    and form_specs[1].questions[1].label == "Q2",
  "morph spec 第 1 题逐字携带 label（validate 携带 → spec 自动携带）"
)
check(
  form_specs[1].questions[2].label == "",
  "morph spec 缺省 label 归一为空串（validate 缺省携带）"
)

-- 1f) label 非 string → 整体无效 → 重试路径（失败原因附 label 措辞），重试成功出 form
script = {
  { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false, label = 42 } } },
  { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false } } },
}
form_specs = {}
adapter_log = {}
question_mod.ask()
check(
  #adapter_log == 2 and adapter_log[2].system:find("label 必须是 string", 1, true) ~= nil,
  "label 非 string → 整体无效并重试（失败原因附 questions[k] label 必须是 string）"
)
check(
  form_specs[1] ~= nil
    and form_specs[1].mode == "form"
    and form_specs[1].questions[1].label == "",
  "label 无效重试成功 → form 表单（重试轮缺省 label 归一空串）"
)

-- 2) 无效 JSON 重试 1 次后成功（重试 system 附上次失败原因；不重读终端）
script = { "simulated bad json", { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = true } } } }
form_specs = {}
read_log = {}
adapter_log = {}
question_mod.ask()
check(#read_log == 1, "重试不重读终端（agent read 仅 1 次）")
check(#adapter_log == 2, "失败后重试 1 次（ask 共 2 次）")
check(adapter_log[2].system:find("simulated bad json", 1, true) ~= nil, "重试 system 附上次失败原因")
check(
  form_specs[1] ~= nil and form_specs[1].mode == "form" and form_specs[1].questions[1].multiple == true,
  "重试成功出 form 表单"
)

-- 3) 两次失败 → fallback（raw_text 携带捕获文本）
script = { "http 500", "still failing" }
form_specs = {}
question_mod.ask()
check(#form_specs == 1 and form_specs[1].mode == "fallback", "两次失败 → fallback 表单")
check(type(form_specs[1].raw_text) == "string" and #form_specs[1].raw_text > 0, "fallback 携带捕获文本")

-- 4) no_question → fallback；complete 但 questions 空数组/缺失视为 no_question
script = { { status = "no_question" } }
form_specs = {}
question_mod.ask()
check(form_specs[1].mode == "fallback", "no_question → fallback 表单")
script = { { status = "complete", questions = {} } }
form_specs = {}
question_mod.ask()
check(form_specs[1].mode == "fallback", "complete 且 questions 空数组视为 no_question → fallback")

-- 4b) 校验失败（题内 suggested 越界 → 整体无效）：无效 → 重试 → 仍失败 fallback
script = {
  {
    status = "complete",
    questions = {
      { question = "Q1", options = { "a" }, multiple = false },
      { question = "Q2", options = { "b" }, multiple = false, suggested = { 5 } },
    },
  },
  {
    status = "complete",
    questions = {
      { question = "Q1", options = { "a" }, multiple = false },
      { question = "Q2", options = { "b" }, multiple = false, suggested = { 9 } },
    },
  },
}

form_specs = {}
adapter_log = {}
question_mod.ask()
check(#adapter_log == 2, "题内 suggested 越界 → 整体无效并重试")
check(form_specs[1].mode == "fallback", "无效重试后仍失败 → fallback")

-- 4c) 阶段流：capture → extract → read_more "1/2" → complete 原位 morph（loading 恰一次）
script = {
  { status = "need_more" },
  { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false } } },
}
form_specs, stage_log, loading_handles = {}, {}, {}
local lc0 = loading_calls
question_mod.ask()
check(loading_calls == lc0 + 1, "ask 开场即 open_loading（恰一次）")
check(
  #stage_log == 3
    and stage_log[1].stage == "capture"
    and stage_log[1].detail == nil
    and stage_log[2].stage == "extract"
    and stage_log[2].detail == nil
    and stage_log[3].stage == "read_more"
    and stage_log[3].detail == "1/2",
  "阶段序列 capture → extract → read_more（detail 携带 N/M）"
)
check(#form_specs == 1 and form_specs[1].mode == "form", "完成后原位 morph_to form 表单")

-- 4d) 重试轮阶段：retry 携带上次失败原因
script = { "simulated bad json", { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = true } } } }
form_specs, stage_log = {}, {}
question_mod.ask()
check(
  #stage_log == 3
    and stage_log[1].stage == "capture"
    and stage_log[2].stage == "extract"
    and stage_log[3].stage == "retry"
    and stage_log[3].detail == "simulated bad json",
  '重试轮 set_stage("retry") 且 detail 为上次失败原因'
)
check(#form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].multiple == true, "重试成功原位 morph form 表单")

-- 4e) capture 失败：仍先 open_loading，再 morph fallback（raw_text 为空串）
form_specs, stage_log = {}, {}
local lc1 = loading_calls
utils.set_exec(function(argv)
  if argv[2] == "agent" and argv[3] == "read" then
    return { code = 1, stdout = "", stderr = "read boom" }
  end
  return qa_exec(argv)
end)
question_mod.ask()
utils.set_exec(qa_exec)
check(loading_calls == lc1 + 1, "capture 失败路径仍先 open_loading")
check(
  #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text == "",
  "capture 失败 → morph fallback（raw_text 空文本）"
)

-- 5) 提交：表单回调 text → delivery 文本通道 send-text（原文逐行 + 括号粘贴）+ 提交键；
--    qa1 已注册且 blocked —— 不允许出现 agent prompt（agent_blocked 拒收面）
script = {
  { status = "complete", questions = { { question = "Approve?", options = { "allow", "deny" }, multiple = false, suggested = {} } } },
}
form_specs = {}
question_mod.ask()
check(form_specs[1].mode == "form", "form 表单已打开（提交用例前置）")
submitted = {}
form_submit("allow\ncustom note")
local q_sent_text, q_sent_key, saw_prompt = nil, nil, false
for _, s in ipairs(submitted) do
  if s.kind == "text" then
    q_sent_text = s.payload
  end
  if s.kind == "key" then
    q_sent_key = s.key
  end
  if s.kind == "prompt" then
    saw_prompt = true
  end
end
check(q_sent_text ~= nil, "提交经 send-text（delivery 文本通道）")
check(
  q_sent_text:find("allow", 1, true) ~= nil and q_sent_text:find("custom note", 1, true) ~= nil,
  "send-text 携带原文逐行文本"
)
check(q_sent_text:find("\27[200~", 1, true) ~= nil, "多行答案经括号粘贴编码（防逐行误提交）")
check(q_sent_key == "enter", "提交键 enter 已发送")
check(not saw_prompt, "blocked 注册 agent 不走 agent prompt（agent_blocked 拒收面）")
check(cfg.options.delivery.agent_channel == true, "文本通道圈定已复原（不影响后续投递）")

-- 5b) esc 取消：closed 句柄后迟到的 llm 回调不 morph、不开表单、不再 warn；
--     closed 句柄上 set_stage / morph_to 均 no-op（UI 契约）
local held_cb
llm.set_adapter(function(opts, cb)
  held_cb = cb -- 挂起回调：模拟异步迟到投递
end)
script = {}
form_specs, stage_log, loading_handles = {}, {}, {}
question_mod.ask()
check(#loading_handles == 1 and loading_handles[1].closed == false, "esc 用例前置：loading 已开且未 closed")
check(
  stage_log[1].stage == "capture" and stage_log[2].stage == "extract",
  "esc 用例前置：骨架已进入 extract 阶段"
)
loading_handles[1].closed = true -- 模拟 esc 取消
local esc_notify = {}
local qa_saved_notify_esc = vim.notify
vim.notify = function(msg)
  table.insert(esc_notify, tostring(msg))
end
held_cb({ status = "complete", questions = { { question = "Q", options = { "a" }, multiple = false } } }, nil)
vim.notify = qa_saved_notify_esc
check(#form_specs == 0, "esc 后迟到回调不 morph（不开表单）")
check(#esc_notify == 0, "esc 后迟到回调不再 warn/notify 打扰")
loading_handles[1].set_stage("extract", "late")
loading_handles[1].morph_to({ mode = "form" }, function() end)
check(#form_specs == 0 and #stage_log == 2, "closed 句柄 set_stage/morph_to 均 no-op")
llm.set_adapter(script_adapter)

-- 6) 提示层：AIAgentBlocked 提醒（llm.hint 开关）
local notified = {}
local qa_saved_notify = vim.notify
vim.notify = function(msg)
  table.insert(notified, tostring(msg))
end
question_mod.notify_blocked({ tool = "opencode", pane_id = "p9" })
check(#notified == 1 and notified[1]:find(":AIQuestion", 1, true) ~= nil, "blocked 提醒含 :AIQuestion 指引")
cfg.options.llm.hint = false
question_mod.notify_blocked({ tool = "opencode" })
check(#notified == 1, "llm.hint=false 时静默")
vim.notify = qa_saved_notify

-- ---------------------------------------------------------------------------
-- 7) :AIQuestionDev —— 本地文件 / 当前 buffer 驱动提问表单（dev，提交不投递）
-- ---------------------------------------------------------------------------
local dev_cmds = vim.api.nvim_get_commands({})
check(dev_cmds.AIQuestionDev ~= nil, ":AIQuestionDev 命令已注册")
check(
  dev_cmds.AIQuestionDev.nargs == "?" and dev_cmds.AIQuestionDev.complete == "file",
  ":AIQuestionDev 定义为 -nargs=? -complete=file"
)

-- 7a) .json 文件 = fixture：validate 后 morph form；adapter 不被调用、无终端捕获
local dev_fix = vim.fn.tempname() .. ".json"
vim.fn.writefile({
  vim.json.encode({
    status = "complete",
    questions = { { question = "Proceed?", options = { "yes", "no" }, multiple = false, suggested = { 1 } } },
  }),
}, dev_fix)
form_specs, stage_log, read_log, adapter_log, submitted = {}, {}, {}, {}, {}
local dev_lc0 = loading_calls
question_mod.ask_dev(dev_fix)
check(loading_calls == dev_lc0 + 1, "fixture 模式同样开场 open_loading（恰一次）")
check(#form_specs == 1 and form_specs[1].mode == "form", "有效 fixture → morph form 表单")
check(
  type(form_specs[1].questions) == "table"
    and #form_specs[1].questions == 1
    and form_specs[1].questions[1].question == "Proceed?"
    and form_specs[1].questions[1].options[1] == "yes"
    and form_specs[1].questions[1].options[2] == "no"
    and form_specs[1].questions[1].multiple == false
    and form_specs[1].questions[1].suggested[1] == 1,
  "fixture morph spec questions[] 逐字段携带每题字段"
)
check(#adapter_log == 0 and #read_log == 0, "fixture 模式跳过网络与终端（adapter 与 herdr read 均未被调用）")

-- 7b) fixture decode 失败：warn 附原因 + 原文进 :messages → fallback（原文预览），无投递
vim.fn.writefile({ "{definitely not json" }, dev_fix)
form_specs, submitted, read_log = {}, {}, {}
local dev_notes = {}
local dev_saved_notify = vim.notify
vim.notify = function(msg, level)
  table.insert(dev_notes, { msg = tostring(msg), level = level })
end
question_mod.ask_dev(dev_fix)
local dev_bad_json_warn
for _, n in ipairs(dev_notes) do
  if n.level == vim.log.levels.WARN and n.msg:find("解析失败", 1, true) then
    dev_bad_json_warn = n.msg
  end
end
check(dev_bad_json_warn ~= nil, "坏 JSON fixture → warn 附解析原因")
check(
  #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text == "{definitely not json",
  "坏 JSON fixture → fallback 表单（raw_text = 原文预览）"
)
check(#submitted == 0, "坏 JSON fixture 不产生任何投递")

-- 7c) fixture 校验无效（合法 JSON 坏 schema）：warn 附原因 → fallback，无投递
vim.fn.writefile({
  vim.json.encode({ status = "complete", questions = { { question = "Q", options = {}, multiple = false } } }),
}, dev_fix)
form_specs, submitted = {}, {}
dev_notes = {}
question_mod.ask_dev(dev_fix)
local dev_bad_schema_warn
for _, n in ipairs(dev_notes) do
  if n.level == vim.log.levels.WARN and n.msg:find("校验无效", 1, true) then
    dev_bad_schema_warn = n.msg
  end
end
check(dev_bad_schema_warn ~= nil, "校验无效 fixture → warn 附失败原因")
check(
  #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text:find("options", 1, true) ~= nil,
  "校验无效 fixture → fallback（原文预览）"
)
check(#submitted == 0, "校验无效 fixture 不产生任何投递")
vim.notify = dev_saved_notify

-- 7d) 非 json 文件 = 全真：文件全文作为捕获文本（走注入 adapter），出 form 表单
local dev_txt = vim.fn.tempname() .. ".txt"
vim.fn.writefile({ "agent asks: pick one?", "[1] yes [2] no" }, dev_txt)
script = { { status = "complete", questions = { { question = "Pick?", options = { "yes", "no" }, multiple = false } } } }
form_specs, adapter_log, stage_log, read_log = {}, {}, {}, {}
dev_notes = {}
vim.notify = function(msg)
  table.insert(dev_notes, tostring(msg))
end
question_mod.ask_dev(dev_txt)
check(
  #adapter_log == 1
    and adapter_log[1].user:find("agent asks: pick one?", 1, true) ~= nil
    and adapter_log[1].user:find("[1] yes [2] no", 1, true) ~= nil,
  "全真模式：文件全文作为捕获文本送 LLM（adapter 真调用一次）"
)
check(#form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Pick?", "全真模式 → form 表单")
check(#read_log == 0, "全真模式不捕获 herdr 终端（文件顶替 capture）")
local dev_stats_msg, dev_raw_msg
for _, m in ipairs(dev_notes) do
  if m:find("AIQuestionDev", 1, true) and m:find("统计", 1, true) then
    dev_stats_msg = m
  end
  if m:find("原始 LLM JSON 响应", 1, true) then
    dev_raw_msg = m
  end
end
check(
  dev_stats_msg ~= nil
    and dev_stats_msg:find("题数=1", 1, true) ~= nil
    and dev_stats_msg:find("read-more 轮数=0", 1, true) ~= nil
    and dev_stats_msg:find("重试次数=0", 1, true) ~= nil
    and dev_stats_msg:find("总耗时=", 1, true) ~= nil,
  "全真模式 :messages 携带统计（题数 / read-more 轮数 / 重试次数 / 总耗时）"
)
check(dev_raw_msg ~= nil and dev_raw_msg:find("Pick?", 1, true) ~= nil, "全真模式 :messages 携带末轮原始 LLM JSON 响应全文")

-- 7e) 全真 read-more：轮次与 stage 流照常展示，但重发的仍是同一份文件全文
script = {
  { status = "need_more" },
  { status = "complete", questions = { { question = "Again?", options = { "a" }, multiple = false } } },
}
form_specs, stage_log, adapter_log = {}, {}, {}
question_mod.ask_dev(dev_txt)
check(
  #stage_log == 3
    and stage_log[1].stage == "capture"
    and stage_log[2].stage == "extract"
    and stage_log[3].stage == "read_more"
    and stage_log[3].detail == "1/2",
  "全真模式阶段流 capture → extract → read_more（detail 1/2）照常展示"
)
local dev_body1 = adapter_log[1] and adapter_log[1].user:match("<<<BEGIN>>>\n(.*)\n<<<END>>>")
local dev_body2 = adapter_log[2] and adapter_log[2].user:match("<<<BEGIN>>>\n(.*)\n<<<END>>>")
check(
  #adapter_log == 2 and dev_body1 ~= nil and dev_body1 == dev_body2 and dev_body1:find("agent asks: pick one?", 1, true) ~= nil,
  "read-more 轮重发同一份文件内容（行数翻倍对文件无意义）"
)
check(#form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Again?", "全真 read-more 后 morph form 表单")

-- 7f) 全真重试照常：失败 → retry 阶段（附原因）→ 成功出 form
script = { "dev simulated failure", { status = "complete", questions = { { question = "R?", options = { "a" }, multiple = false } } } }
form_specs, stage_log, adapter_log = {}, {}, {}
question_mod.ask_dev(dev_txt)
check(
  #adapter_log == 2 and stage_log[3].stage == "retry" and stage_log[3].detail == "dev simulated failure",
  "全真模式失败 → retry 阶段（detail 携带原因）"
)
check(#form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "R?", "全真重试成功 morph form 表单")

-- 7g) dev 提交：只打 info 日志（未投递）；假 exec 日志必须为空
submitted = {}
form_submit("yes\ndev note")
check(#submitted == 0, "AIQuestionDev 提交绝不投递（无 send-text / send-keys / agent prompt）")
local dev_submit_msg
for _, m in ipairs(dev_notes) do
  if m:find("提交文本（未投递）", 1, true) then
    dev_submit_msg = m
  end
end
check(
  dev_submit_msg ~= nil and dev_submit_msg:find("yes", 1, true) ~= nil and dev_submit_msg:find("dev note", 1, true) ~= nil,
  "提交打 info 日志（提交文本（未投递）+ 全文）"
)
vim.notify = dev_saved_notify

-- 7h) 无参数 = 当前 buffer 判定：filetype json → fixture 路径
vim.cmd("enew!")
local dev_buf = vim.api.nvim_get_current_buf()
vim.bo[dev_buf].filetype = "json"
vim.api.nvim_buf_set_lines(dev_buf, 0, -1, false, { vim.json.encode({ status = "no_question" }) })
form_specs, adapter_log, read_log = {}, {}, {}
question_mod.ask_dev()
check(
  #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text:find("no_question", 1, true) ~= nil,
  "无参数 + filetype json buffer → fixture 路径（no_question → fallback 原文）"
)
check(#adapter_log == 0 and #read_log == 0, "json buffer fixture 不调用 LLM / 终端")

-- 7i) 无参数：buffer 名以 .json 结尾 → fixture 路径（有效 fixture → form）
vim.fn.writefile({
  vim.json.encode({
    status = "complete",
    questions = { { question = "Proceed?", options = { "yes", "no" }, multiple = false, suggested = { 1 } } },
  }),
}, dev_fix)
vim.cmd("edit " .. vim.fn.fnameescape(dev_fix))
form_specs, adapter_log = {}, {}
question_mod.ask_dev()
check(
  #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Proceed?",
  "无参数 + buffer 名 .json 结尾 → fixture 路径（morph form）"
)

-- 7j) 无参数 + 非 json buffer = 全真：buffer 全部行 join 作为捕获文本
vim.cmd("enew!")
dev_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(dev_buf, 0, -1, false, { "buffer asks:", "[1] yes [2] no" })
script = { { status = "complete", questions = { { question = "Buf?", options = { "y" }, multiple = false } } } }
adapter_log, form_specs = {}, {}
question_mod.ask_dev()
check(
  #adapter_log == 1
    and adapter_log[1].user:find("buffer asks:", 1, true) ~= nil
    and adapter_log[1].user:find("[1] yes [2] no", 1, true) ~= nil,
  "无参数 + 非 json buffer → buffer 全文（逐行 join）作为捕获文本"
)
check(#form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Buf?", "无参数 buffer 全真管线 → form 表单")
vim.cmd("enew!")

-- ---------------------------------------------------------------------------
-- 8) auto 触发（llm.auto_question）：事件路由 → 预过滤 → 静默编排 → morph 前复查
-- ---------------------------------------------------------------------------
check(type(question_mod.looks_like_question) == "function", "looks_like_question 已导出")
check(
  question_mod.looks_like_question("Proceed? (a) yes (b) no")
    and question_mod.looks_like_question("继续吗？请选择")
    and question_mod.looks_like_question("pick one: [1] yes [2] no")
    and question_mod.looks_like_question("1. Docker 2. bare metal")
    and question_mod.looks_like_question("请选择选项")
    and question_mod.looks_like_question("options: a / b")
    and question_mod.looks_like_question("(A) allow (B) deny")
    and question_mod.looks_like_question("需要确认❓"),
  "looks_like_question 正例：？/?/❓/(a)/(A)/[1]/1./选项/options 各特征命中"
)
check(
  not question_mod.looks_like_question("Building project... done in 3s")
    and not question_mod.looks_like_question("All checks passed\nWrote 5 files")
    and not question_mod.looks_like_question(""),
  "looks_like_question 负例：纯构建/进度日志不命中"
)
check(
  vim.deep_equal(cfg.options.llm.auto_question_states, { "blocked", "done" })
    and cfg.options.llm.auto_question == false,
  "llm.auto_question 默认关、auto_question_states 默认 blocked+done"
)

-- 前置：此前手动/dev 用例遗留的表单句柄统一置 closed，让 auto_check 的
-- 防叠窗守卫从干净状态开始（记录最近 handle 的模块级变量即可通过入口检查）
for _, h in ipairs(loading_handles) do
  h.closed = true
end
cfg.options.llm.auto_question = true
form_specs, stage_log, loading_handles = {}, {}, {}
local ac_lc = loading_calls
local ac_adapter = #adapter_log
local ac_rl = #read_log
local saved_warn_q = utils.warn
local q_warns = {}
utils.warn = function(msg)
  table.insert(q_warns, tostring(msg))
end
local close_last_handle = function()
  local h = loading_handles[#loading_handles]
  if h then
    h.closed = true
  end
end

-- 8a) 预过滤不通过：无 loading、无 LLM 调用、完全静默
read_pages = { "Build finished successfully. All 42 checks green in 3s" }
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(loading_calls == ac_lc, "auto 预过滤不通过 → 不弹 loading 骨架")
check(#adapter_log == ac_adapter, "auto 预过滤不通过 → 不调 LLM")
check(#read_log == ac_rl + 1, "auto 预过滤：先本地捕获 pane 输出（恰一次 read）")
check(#q_warns == 0 and #form_specs == 0, "auto 预过滤不通过 → 完全静默（无 warn 无表单）")
ac_rl = #read_log

-- 8b) 预过滤通过 → 提取 complete → morph 前复查仍 blocked → morph form
script = { { status = "complete", questions = { { question = "Auto?", options = { "y", "n" }, multiple = false } } } }
qa_agents = { qa1 = "blocked" }
form_specs = {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(loading_calls == ac_lc + 1, "auto_check 通过预过滤后开 loading（恰一次）")
check(
  #read_log == ac_rl + 2, -- 预过滤捕获 1 次 + 编排入口 capture 阶段再捕获 1 次
  "auto_check 捕获该 pane 输出（预过滤 + 编排 capture 各一次 herdr agent read）"
)
check(
  #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Auto?",
  "auto complete → morph form 表单"
)
close_last_handle() -- 收口本用例的表单句柄（防叠窗守卫按 closed 判定）
ac_lc = loading_calls

-- 8c) no_question → 骨架被关、无 morph、无 fallback、无 warn（完全静默）
script = { { status = "no_question" } }
form_specs = {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(loading_calls == ac_lc + 1, "auto no_question 路径同样先开 loading 骨架")
check(#form_specs == 0, "auto no_question → 不 morph、不弹 fallback 表单")
check(loading_handles[#loading_handles].closed, "auto no_question → 骨架被静默关闭")
check(#q_warns == 0, "auto no_question → 无 warn（stub utils.warn 计数为零）")
ac_lc = loading_calls

-- 8d) 提取失败耗尽重试 → 完全静默（关骨架，无 fallback 无 warn）
script = { "http 500", "still failing" }
form_specs = {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(#form_specs == 0 and loading_handles[#loading_handles].closed, "auto 提取失败耗尽 → 静默关骨架（无 fallback 表单）")
check(#q_warns == 0, "auto 提取失败 → 无 warn")
ac_lc = loading_calls

-- 8e) 上一个 handle 未 closed（表单/loading 还开着）→ auto_check 跳过
local held_auto_cb
llm.set_adapter(function(opts, cb)
  held_auto_cb = cb -- 挂起回调：模拟表单开着期间（提取未收尾）的下一次触发
end)
form_specs, loading_handles = {}, {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(loading_calls == ac_lc + 1 and loading_handles[1] and not loading_handles[1].closed, "跳过用例前置：auto 骨架开着未关")
local ac_adapter_held = #adapter_log
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "done")
check(loading_calls == ac_lc + 1, "上一个 handle 未 closed → auto_check 跳过（done 触发同样拦下）")
check(#adapter_log == ac_adapter_held, "跳过路径不调 LLM（入口守卫在捕获之前）")
loading_handles[1].closed = true -- 收场（closed 句柄上迟到回调应被静默丢弃）
held_auto_cb({ status = "complete", questions = { { question = "Q", options = { "a" }, multiple = false } } }, nil)
check(#form_specs == 0, "closed 句柄上 auto 的迟到回调静默丢弃")
llm.set_adapter(script_adapter)
ac_lc = loading_calls

-- 8f) morph 前复查：pane 已回 working → 静默关骨架不弹
script = { { status = "complete", questions = { { question = "Late?", options = { "a" }, multiple = false } } } }
qa_agents = { qa1 = "working" }
form_specs = {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(loading_calls == ac_lc + 1, "复查用例：编排照常开 loading")
check(#form_specs == 0 and loading_handles[#loading_handles].closed, "morph 前复查回 working → 静默关骨架不弹")
check(#q_warns == 0, "复查不通过静默收场（无 warn）")
ac_lc = loading_calls

-- 8g) 复查 exec 失败（agent list 挂了）→ 按仍在触发集处理（宁可多弹一次）
utils.set_exec(function(argv)
  if argv[2] == "agent" and argv[3] == "list" then
    return { code = 1, stdout = "", stderr = "list boom" }
  end
  return qa_exec(argv)
end)
qa_agents = { qa1 = "blocked" }
script = { { status = "complete", questions = { { question = "Risky?", options = { "a" }, multiple = false } } } }
form_specs = {}
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "blocked")
check(#form_specs == 1 and form_specs[1].mode == "form", "复查失败（exec 错）→ 按仍在触发集处理，照常 morph form")
utils.set_exec(qa_exec)
close_last_handle()
ac_lc = loading_calls

-- 8h) 状态集过滤：auto_question_states 之外的状态不触发
local al_before_states = #adapter_log
question_mod.auto_check({ pane_id = "qa1", tool = "qa" }, "working")
check(loading_calls == ac_lc and #adapter_log == al_before_states, "auto_question_states 之外的状态（working）不触发")

-- 8i) auto_question=false → 仅 blocked 走原 hint（done 无 hint、无提取）
cfg.options.llm.auto_question = false
cfg.options.llm.hint = true -- 上文 6) 用例把 hint 置 false 后未复原，这里显式开回
local ac_notified = {}
local qa_saved_notify_auto = vim.notify
vim.notify = function(msg)
  table.insert(ac_notified, tostring(msg))
end
question_mod.on_agent_state({ tool = "opencode", pane_id = "p9" }, "AIAgentBlocked")
check(#ac_notified == 1 and ac_notified[1]:find(":AIQuestion", 1, true) ~= nil, "auto off + blocked → 原 notify hint 不变")
question_mod.on_agent_state({ tool = "opencode", pane_id = "p9" }, "AIAgentDone")
check(#ac_notified == 1 and loading_calls == ac_lc, "auto off + done → 无 hint、不触发提取（骨架数不变）")
vim.notify = qa_saved_notify_auto

-- 8j) AIAgentDone 订阅存在 + 全链路：emit 事件 → 自动提取 → morph form
cfg.options.llm.auto_question = true
local ok_ac, done_autocmds = pcall(vim.api.nvim_get_autocmds, { event = "User", pattern = "AIAgentDone" })
check(ok_ac and type(done_autocmds) == "table" and #done_autocmds > 0, "init.setup 订阅 AIAgentDone User 事件")
qa_agents = { qa1 = "done" } -- 复查时 done ∈ 触发集 → 放行
script = { { status = "complete", questions = { { question = "Done?", options = { "ok" }, multiple = false } } } }
form_specs = {}
utils.emit("AIAgentDone", { tool = "qa", pane_id = "qa1", status = "done", cwd = "/tmp" })
check(#form_specs == 1 and form_specs[1].mode == "form", "AIAgentDone 事件全链路：轮询状态 → 事件 → auto 提取 → morph form")
close_last_handle()

utils.warn = saved_warn_q

-- 还原本节注入与配置
llm.set_adapter(nil)
utils.set_exec(nil)
utils.set_exec_to_file(nil)
utils.set_exec_async(nil)
package.preload["herder-agents.ui.question_form"] = nil
delivery._reset()
cfg.options.tools.qatool = nil
cfg.options.tool_order = vim.tbl_filter(function(n)
  return n ~= "qatool"
end, cfg.options.tool_order)
vim.g.ai_tool = qa_saved_tool
cfg.options.llm = qa_saved_llm
if qa_saved_key then
  vim.env.DEEPSEEK_API_KEY = qa_saved_key
else
  vim.env.DEEPSEEK_API_KEY = nil
end
end
run_question_tests() -- 提问表单用例块装进函数：局部变量作用域随函数收束，避开 main chunk 200 上限

print("ALL PASSED")
