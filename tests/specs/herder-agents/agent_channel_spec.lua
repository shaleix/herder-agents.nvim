-- delivery agent 集成通道（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("delivery agent 集成通道", function()
  it("delivery agent 集成通道", function()
    local utils = require("herder-agents.utils")
    local delivery = require("herder-agents.delivery")

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
    assert.truthy(ok_agent == true, "agent 通道 deliver 受理")
    assert.truthy(agent_done == true, "agent prompt on_done 成功")
    assert.truthy(
      argv_contains(function(argv)
        return argv[2] == "agent" and argv[3] == "prompt" and argv[4] == "p-agent" and argv[5] == "hello\nmulti line"
      end),
      "agent 通道用 agent prompt 提交（原文直传）"
    )
    assert.truthy(not argv_contains(function(argv)
      return argv[3] == "send-text"
    end), "agent 通道不再走 send-text（无 paste 编码）")

    -- 1b) agent 通道 + 结尾 @文件（附件块形状）→ 原文补一个空格关补全
    -- （服务端补按的回车否则会被"接受补全"吃掉，消息不提交）
    fake_agents = { ["p-agent"] = "idle" }
    argv_log = {}
    delivery.deliver("p-agent", "codex", "review this\n\nRelate file:\n- @src/foo.lua", { submit_key = "enter" })
    assert.truthy(
      argv_contains(function(argv)
        return argv[3] == "prompt" and argv[5] == "review this\n\nRelate file:\n- @src/foo.lua "
      end),
      "agent prompt：结尾 @token 补一个空格（关闭补全弹层）"
    )
    argv_log = {}
    delivery.deliver("p-agent", "codex", "- $my-skill", { submit_key = "enter" })
    assert.truthy(
      argv_contains(function(argv)
        return argv[3] == "prompt" and argv[5] == "- $my-skill "
      end),
      "agent prompt：结尾 $技能 token 同样补空格"
    )
    argv_log = {}
    delivery.deliver("p-agent", "codex", "plain text ending.", { submit_key = "enter" })
    assert.truthy(
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
    assert.truthy(ok_text == true, "文本通道 deliver 成功")
    local sent_text, sent_key = nil, nil
    for _, argv in ipairs(argv_log) do
      if argv[3] == "send-text" then
        sent_text = argv[5]
      end
      if argv[3] == "send-keys" then
        sent_key = argv[5]
      end
    end
    assert.truthy(
      sent_text ~= nil and sent_text:find("\27[200~", 1, true) ~= nil,
      "文本通道保留 bracketed paste 编码"
    )
    assert.truthy(sent_key == "enter", "文本通道补提交键 enter")
    assert.truthy(not argv_contains(function(argv)
      return argv[3] == "prompt"
    end), "未注册 pane 不走 agent prompt")

    -- 3) tab 提交（codex /queue）即使已注册也走文本通道
    fake_agents = { ["p-tab"] = "idle" }
    argv_log = {}
    delivery.deliver("p-tab", "codex", "/queue task", { submit_key = "tab", paste_wrap = true })
    assert.truthy(not argv_contains(function(argv)
      return argv[3] == "prompt"
    end), "tab 提交（/queue）不走 agent prompt")
    assert.truthy(
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
    assert.truthy(
      ok_q == true and delivery.pending_count() == 1,
      "unknown 状态进入排队（settle 复查后送出）"
    )
    vim.wait(3000, function()
      return delivery.pending_count() == 0
    end, 20)
    assert.truthy(delivery.pending_count() == 0, "unknown 经 settle 复查后自动 flush（不再死锁）")
    assert.truthy(not argv_contains(function(argv)
      return argv[3] == "wait"
    end), "unknown 不再调用 agent wait（旧版对 codex 无限超时）")
    assert.truthy(
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
    assert.truthy(delivery.pending_count() == 1, "blocked 状态进入排队（不向弹窗送输入）")
    vim.wait(4000, function()
      return delivery.pending_count() == 0
    end, 20)
    assert.truthy(delivery.pending_count() == 0, "blocked 解除后自动 flush")
    assert.truthy(
      argv_contains(function(argv)
        return argv[3] == "wait" and argv[4] == "p-blocked" and vim.tbl_contains(argv, "unknown")
      end),
      "blocked 经 agent wait 等待（匹配集含 unknown）"
    )
    assert.truthy(
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
    assert.truthy(not argv_contains(function(argv)
      return argv[3] == "prompt"
    end), "agent_channel=false 强制文本通道")
    assert.truthy(
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
    assert.truthy(#status_events == 3, "agent list 轮询发出 idle/working/done 事件（unknown 不发）")
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
    assert.truthy(saw_working, "AIAgentWorking 事件 payload 正确")
    assert.truthy(saw_done, "AIAgentDone 事件已发出（done 状态映射，payload 形状一致）")
    assert.truthy(saw_cwd, "事件 payload 含 agent cwd")
    status_mod._tick()
    assert.truthy(#status_events == 3, "状态未变不重复发事件")
    fake_agents["s2"] = "working"
    status_mod._tick()
    assert.truthy(#status_events == 4 and status_events[4].match == "AIAgentWorking", "状态变化发出新事件")
    fake_agents = { ["s-other"] = "working" }
    fake_ws = "w-other"
    status_events = {}
    status_mod._tick()
    assert.truthy(#status_events == 0, "其他 workspace 的 agent 被过滤")
    fake_ws = "w-test"
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
    status_mod._reset()
  end)
end)
