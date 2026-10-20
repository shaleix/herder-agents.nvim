-- delivery / context 上限 / 事件（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

-- 独立实例基线：原单文件套件由 plugin 段先 setup（命令注册、默认不绑键）；
-- plenary 每个 spec 一个新 nvim 实例，这里自建同样基线。
vim.g.mapleader = " "
require("herder-agents").setup({ tools = { mycli = { title = " My CLI Chat " } } })

describe("delivery / context 上限 / 事件", function()
  it("delivery / context 上限 / 事件", function()
    -- ---------------------------------------------------------------------------
    -- delivery / context 上限 / 事件（借鉴 codex.nvim 的机制）
    -- ---------------------------------------------------------------------------
    local delivery = require("herder-agents.delivery")
    local utils = require("herder-agents.utils")

    -- context 上限：超限拒绝而非截断
    local ctx_cfg = require("herder-agents.config").options.context
    assert.truthy(ctx_cfg.max_lines == 500 and ctx_cfg.max_bytes == 65536, "context 上限默认 500 行 / 64KB")
    local context2 = require("herder-agents.context")
    local big_lines = {}
    for i = 1, 501 do
      big_lines[i] = "line" .. i
    end
    assert.truthy(
      context2._check_limits(big_lines, table.concat(big_lines, "\n")) ~= nil,
      "选区超行数上限被拒绝"
    )
    assert.truthy(context2._check_limits({ "a" }, string.rep("x", 65537)) ~= nil, "选区超字节上限被拒绝")
    assert.truthy(context2._check_limits({ "a", "b" }, "ab") == nil, "上限内选区通过")

    -- 草稿绑定校验：pane 被替换时拒绝
    assert.truthy(delivery.check_binding("codex", "pane-1", { pane_id = "pane-1" }), "绑定一致时放行")
    assert.truthy(not delivery.check_binding("codex", "pane-1", { pane_id = "pane-2" }), "pane 被替换时拒绝")
    assert.truthy(
      delivery.check_binding("codex", nil, { pane_id = "pane-2" }),
      "打开时无 pane（nil 绑定）放行"
    )
    assert.truthy(
      delivery.check_binding("codex", "pane-1", nil),
      "提交时无 pane 参数放行（调用方另行报错）"
    )

    -- 空队列丢弃 / 计数
    delivery._reset()
    assert.truthy(delivery.pending_count() == 0, "初始无排队 prompt")
    assert.truthy(delivery.drop_all() == 0, "drop_all 空队列返回 0")

    -- pane 查询：不存在的 pane 不崩溃（无 herdr 守护进程时同样返回 nil/false）
    local running = delivery.pane_agent_running("definitely-not-a-pane")
    assert.truthy(running == nil or running == false, "pane_agent_running 查询失败返回 nil/false 不抛异常")

    -- User 事件（payload 在 event.data）
    local captured = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = { "AIPromptSent", "AIPromptQueued", "AIDeliveryFailed" },
      callback = function(event)
        table.insert(captured, { pattern = event.match, data = event.data })
      end,
    })
    utils.emit("AIPromptSent", { tool = "codex", pane_id = "p1", submitted = true, queued = false })
    assert.truthy(#captured == 1 and captured[1].pattern == "AIPromptSent", "AIPromptSent 事件已发出")
    assert.truthy(
      captured[1].data.tool == "codex" and captured[1].data.queued == false,
      "事件 payload 在 event.data"
    )

    -- :AIDropQueue 命令存在
    local cmds2 = vim.api.nvim_get_commands({})
    assert.truthy(cmds2.AIDropQueue ~= nil, ":AIDropQueue 已创建")

    -- delivery 关闭时（enabled=false）deliver 直接同步投递且以退出码判定：
    -- 本环境无 herdr daemon，send-text 必失败 → 返回 false 并发 AIDeliveryFailed
    require("herder-agents.config").options.delivery.enabled = false
    local done = false
    local ok_delivery = delivery.deliver("definitely-not-a-pane", "codex", "hello", {
      submit_key = "enter",
      on_done = function(ok, queued)
        done = true
        assert.truthy(ok == false and queued == false, "投递失败 on_done(false,false)")
      end,
    })
    assert.truthy(ok_delivery == false, "herdr 不可用时 deliver 返回 false（不再假成功）")
    assert.truthy(done, "on_done 同步回调已执行")
    assert.truthy(
      #captured >= 2 and captured[#captured].pattern == "AIDeliveryFailed",
      "投递失败发出 AIDeliveryFailed"
    )
    require("herder-agents.config").options.delivery.enabled = true
    delivery._reset()

    -- enabled 排队路径：无 herdr daemon 时 ready 探测失败 → 入队返回 true，
    -- 实际投递由 timer 链异步驱动（headless 下不等待触发）
    local ok_queue = delivery.deliver("definitely-not-a-pane", "codex", "hello", { submit_key = "enter" })
    assert.truthy(ok_queue == true, "agent 未就绪时 deliver 入队并返回 true")
    assert.truthy(delivery.pending_count() == 1, "入队后 pending_count 为 1")
    assert.truthy(delivery.drop_all() == 1, "drop_all 丢弃排队项并返回 1")
    assert.truthy(delivery.pending_count() == 0, "丢弃后 pending_count 归零")
    delivery._reset()
  end)
end)
