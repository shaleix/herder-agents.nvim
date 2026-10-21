-- herdr: 提及补全（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("herdr: 提及补全", function()
  local utils = require("herder-agents.utils")

  -- ---------------------------------------------------------------------------
  -- herdr:<pane_id> 提及补全（agents.lua 数据层 + completion/agents.lua 适配层）：
  -- 候选 = `herdr agent list` 的会话级 agent（pane_id 唯一表示）；每次刷新并行拉
  -- agent list + workspace list（id→名 join，名字进 labelDetails 角标）；5s TTL
  -- 缓存（stale-while-refresh，失败静默降级）；current 由 vim.b[buf].pane_id 精确
  -- 匹配。假执行器注入 + 显式控制 HERDR_ENV / HERDR_TAB_ID（ambient shell 可能
  -- 带 HERDR_ENV=1，测试必须自管）；包进局部函数避开主 chunk 200 局部上限
  -- ---------------------------------------------------------------------------
  local function run_agent_completion_tests()
    local agents = require("herder-agents.agents")

    local saved_env = vim.env.HERDR_ENV
    local saved_tab = vim.env.HERDR_TAB_ID
    -- 本段 fixture 无 workspace 域限定断言（专测见 run_workspace_scope_tests）：
    -- 显式关掉 HERDR_WORKSPACE_ID 保证确定性（ambient shell 可能带着，而
    -- fixture 的 workspace_id 是 ws1/ws2，开着会把候选滤空）
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = nil
    local saved_ttl = agents._ttl_ms

    -- fixture：herdr agent list 假响应 —— 两个合法 agent（不同 tab，其一缺
    -- name 且只有未剥离的 terminal_title）+ 一个缺 pane_id 的脏条目（应跳过）
    local fake_json = vim.json.encode({
      result = {
        agents = {
          {
            pane_id = "her1:p2",
            agent = "opencode",
            agent_status = "idle",
            name = "main",
            terminal_title = " opencode: fixing bug ",
            terminal_title_stripped = "opencode: fixing bug",
            cwd = "/repo/a",
            tab_id = "t1",
            workspace_id = "ws1",
          },
          {
            pane_id = "her7:p9",
            agent = "codex",
            agent_status = "working",
            terminal_title = "codex fix bug",
            cwd = "/repo/b",
            tab_id = "t2",
            workspace_id = "ws2",
          },
          { agent = "ghost" }, -- 无 pane_id：规范化时跳过
        },
      },
    })
    -- fixture：herdr workspace list 假响应 —— id→名 join 源（数据层把 label 映到
    -- workspace_id，label 缺失时回落 workspace_id）
    local ws_json = vim.json.encode({
      result = {
        workspaces = {
          { workspace_id = "ws1", label = "repo-a" },
          { workspace_id = "ws2", label = "repo-b" },
        },
      },
    })
    -- 每次刷新 = agent list + workspace list 各一次 CLI：按 argv 分流应答、分开计数
    local agent_calls, ws_calls = 0, 0
    local set_fake_exec = function(on_response)
      utils.set_exec_async(function(argv, on_done)
        if argv[2] == "workspace" then
          ws_calls = ws_calls + 1
        else
          agent_calls = agent_calls + 1
        end
        on_response(on_done, argv)
      end)
    end
    -- 成功应答：agent list / workspace list 各回各的 fixture
    local success_exec = function(on_done, argv)
      if argv[2] == "workspace" then
        on_done({ code = 0, stdout = ws_json, stderr = "" })
      else
        on_done({ code = 0, stdout = fake_json, stderr = "" })
      end
    end
    set_fake_exec(success_exec)

    -- 数据层：HERDR_ENV 门 —— 非 herdr 环境不发起 CLI、直接回 {}
    agents._reset()
    vim.env.HERDR_ENV = nil
    local gated = nil
    agents.list(function(entries)
      gated = entries
    end)
    assert.truthy(gated ~= nil and #gated == 0, "agents 数据层：HERDR_ENV ~= 1 回空列表")
    assert.truthy(
      agent_calls == 0 and ws_calls == 0,
      "agents 数据层：HERDR_ENV 门下不发起 CLI（agent/workspace 均不拉）"
    )

    -- 数据层：解析/规范化（保序、缺 pane_id 跳过、terminal_title_stripped 优先）
    vim.env.HERDR_ENV = "1"
    local listed = nil
    agents.list(function(entries)
      listed = entries
    end)
    assert.truthy(
      listed ~= nil and #listed == 2 and listed[1].pane_id == "her1:p2" and listed[2].pane_id == "her7:p9",
      "agents 数据层：解析 agent list 并保序（缺 pane_id 条目跳过）"
    )
    assert.truthy(
      listed[1].kind == "opencode"
        and listed[1].status == "idle"
        and listed[1].name == "main"
        and listed[1].title == "opencode: fixing bug"
        and listed[1].cwd == "/repo/a"
        and listed[1].tab_id == "t1"
        and listed[1].workspace_id == "ws1"
        and listed[1].workspace == "repo-a",
      "agents 数据层：规范化字段（agent→kind、stripped title 优先、workspace join label）"
    )
    assert.truthy(
      listed[2].name == nil and listed[2].title == "codex fix bug" and listed[2].workspace == "repo-b",
      "agents 数据层：name 可缺失；title 回落未剥离 terminal_title；workspace 按各条目的 id join"
    )
    assert.truthy(agent_calls == 1 and ws_calls == 1, "agents 数据层：首拉恰好 agent+workspace 各一次 CLI")

    -- 数据层：缓存新鲜不再拉取（同步回同一份缓存）
    local again = nil
    agents.list(function(entries)
      again = entries
    end)
    assert.truthy(
      again ~= nil and #again == 2 and again[1].pane_id == "her1:p2",
      "agents 数据层：新鲜缓存同步回列表"
    )
    assert.truthy(
      agent_calls == 1 and ws_calls == 1,
      "agents 数据层：新鲜缓存不 refetch（两条 CLI 均不重发）"
    )

    -- 数据层：stale-while-refresh —— 先回旧列表，刷新在后台（用挂起的执行器拦住
    -- 两条 CLI 的完成回调：agent + workspace 双边到齐 join 才 finalize）
    agents._ttl_ms = 0
    local held = {}
    set_fake_exec(function(on_done, argv)
      if argv[2] == "workspace" then
        held.workspace = on_done -- 不调用：workspace 拉取挂起
      else
        held.agent = on_done -- 不调用：agent 刷新挂起
      end
    end)
    local stale_first = nil
    agents.list(function(entries)
      stale_first = entries
    end)
    assert.truthy(
      stale_first ~= nil and #stale_first == 2 and stale_first[1].pane_id == "her1:p2",
      "agents 数据层：过期先同步回旧列表（stale-while-refresh）"
    )
    assert.truthy(
      held.agent ~= nil and held.workspace ~= nil and agent_calls == 2 and ws_calls == 2,
      "agents 数据层：过期同时后台刷新（agent+workspace 各一次、回调均挂起）"
    )
    -- 刷新完成：in_flight 释放、缓存替换（后续读取拿新数据）
    held.agent({ code = 0, stdout = fake_json, stderr = "" })
    held.workspace({ code = 0, stdout = ws_json, stderr = "" })
    agents._ttl_ms = saved_ttl
    local after_refresh = nil
    agents.list(function(entries)
      after_refresh = entries
    end)
    assert.truthy(
      after_refresh ~= nil and #after_refresh == 2 and after_refresh[1].workspace == "repo-a",
      "agents 数据层：join 完成后缓存更新（含 workspace 名）、读取恢复同步"
    )

    -- 数据层：无缓存时挂起回调，首拉完成统一 flush（agent+workspace 各发一次，
    -- 双边回调到齐 join 后全部挂起回调一并收到）
    agents._reset()
    agent_calls, ws_calls = 0, 0
    held = {}
    set_fake_exec(function(on_done, argv)
      if argv[2] == "workspace" then
        held.workspace = on_done -- 挂起首拉（计数由外层包装负责）
      else
        held.agent = on_done
      end
    end)
    local pend_a, pend_b = nil, nil
    agents.list(function(entries)
      pend_a = entries
    end)
    agents.list(function(entries)
      pend_b = entries
    end)
    -- 注：agent_calls/ws_calls 由 set_fake_exec 的外层包装计数（on_response 不重复计数）
    assert.truthy(
      pend_a == nil and pend_b == nil and agent_calls == 1 and ws_calls == 1,
      "agents 数据层：无缓存时回调挂起、agent/workspace 各只发一次"
    )
    held.agent({ code = 0, stdout = fake_json, stderr = "" })
    assert.truthy(
      pend_a == nil and pend_b == nil,
      "agents 数据层：仅单边回调完成不 flush（join 等 workspace）"
    )
    held.workspace({ code = 0, stdout = ws_json, stderr = "" })
    assert.truthy(
      pend_a ~= nil and pend_b ~= nil and #pend_a == 2 and #pend_b == 2,
      "agents 数据层：双边到齐后统一 flush 全部挂起回调"
    )

    -- 数据层：agent list 失败（有缓存）保留旧列表、不覆盖缓存（静默，无告警面；
    -- workspace list 此时仍成功 —— agent 数据失败即整轮判失败，不受 join 干扰）
    set_fake_exec(function(on_done, argv)
      if argv[2] == "workspace" then
        on_done({ code = 0, stdout = ws_json, stderr = "" })
      else
        on_done({ code = 1, stdout = "", stderr = "boom" })
      end
    end)
    agents._ttl_ms = 0
    local fail_old = nil
    agents.list(function(entries)
      fail_old = entries
    end)
    assert.truthy(
      fail_old ~= nil and #fail_old == 2 and fail_old[1].pane_id == "her1:p2",
      "agents 数据层：失败先回旧列表"
    )
    local still_old = nil
    agents.list(function(entries)
      still_old = entries
    end)
    assert.truthy(
      still_old ~= nil and #still_old == 2,
      "agents 数据层：失败不覆盖缓存（后续读取仍旧列表）"
    )

    -- 数据层：失败（无缓存，非法 JSON）回 {}（exit 0 但 stdout 非 JSON 同样判失败；
    -- workspace 同样失败 → label 表沿用旧值，不影响空结果判定）
    agents._reset()
    set_fake_exec(function(on_done)
      on_done({ code = 0, stdout = "<not json>", stderr = "" })
    end)
    local fail_empty = nil
    agents.list(function(entries)
      fail_empty = entries
    end)
    assert.truthy(
      fail_empty ~= nil and #fail_empty == 0,
      "agents 数据层：失败且无缓存回 {}（含非法 JSON）"
    )

    -- 数据层：workspace list 失败不拖垮 agent 刷新 —— agent 列表照常更新、
    -- workspace 名沿用旧 label 表；静默降级、无告警
    set_fake_exec(success_exec)
    agents.list(function() end) -- 先成功刷一轮，填充旧 label 表（repo-a/repo-b）
    set_fake_exec(function(on_done, argv)
      if argv[2] == "workspace" then
        on_done({ code = 1, stdout = "", stderr = "ws boom" })
      else
        on_done({ code = 0, stdout = fake_json, stderr = "" })
      end
    end)
    agents._ttl_ms = 0
    local saved_notify = vim.notify
    local ws_fail_notify = {}
    vim.notify = function(msg)
      table.insert(ws_fail_notify, tostring(msg))
    end
    local ws_fail = nil
    agents.list(function(entries)
      ws_fail = entries
    end)
    vim.notify = saved_notify
    assert.truthy(
      ws_fail ~= nil and #ws_fail == 2 and ws_fail[1].pane_id == "her1:p2",
      "agents 数据层：workspace list 失败时 agent 列表照常刷新"
    )
    assert.truthy(
      ws_fail[1].workspace == "repo-a" and ws_fail[2].workspace == "repo-b",
      "agents 数据层：workspace 名沿用旧 label 表（失败不换表）"
    )
    assert.truthy(#ws_fail_notify == 0, "agents 数据层：workspace list 失败静默无告警")

    -- 无旧 label 表（_reset 清空后首拉 workspace 即失败）→ workspace 回落 workspace_id
    agents._reset()
    local ws_fallback = nil
    agents.list(function(entries)
      ws_fallback = entries
    end)
    assert.truthy(
      ws_fallback ~= nil and ws_fallback[1].workspace == "ws1" and ws_fallback[2].workspace == "ws2",
      "agents 数据层：workspace list 失败且无旧表 → 回落 workspace_id"
    )

    -- 数据层：current_pane_id 读 vim.b[buf].pane_id（无绑定/失效 buffer 回 nil）
    local bound_buf = vim.api.nvim_create_buf(false, true)
    vim.b[bound_buf].pane_id = "her1:p2"
    assert.truthy(
      agents.current_pane_id(bound_buf) == "her1:p2",
      "agents 数据层：current_pane_id 读 buffer 绑定"
    )
    local plain_buf = vim.api.nvim_create_buf(false, true)
    assert.truthy(agents.current_pane_id(plain_buf) == nil, "agents 数据层：未绑定 buffer 回 nil")
    assert.truthy(agents.current_pane_id(-1) == nil, "agents 数据层：失效 buffer 回 nil（pcall 兜底）")

    -- 适配层：blink source 接口（触发字符、herdr: 前缀判定、items 形状与打分）
    local adapter = require("herder-agents.completion.agents")
    local source = adapter.new({})
    assert.truthy(
      vim.deep_equal(source:get_trigger_characters(), { ":" }),
      "agents 适配层：get_trigger_characters 返回 :"
    )

    -- 恢复成功执行器 + 有效缓存，供适配层用例复用（绑定/无绑定 buffer 的打分对比）
    agents._reset()
    agent_calls, ws_calls = 0, 0
    set_fake_exec(success_exec)
    agents.list(function() end) -- 预热缓存（agent+workspace 各一次）

    local function fetch_items(ctx)
      local res = nil
      source:get_completions(ctx, function(r)
        res = r
      end)
      return res
    end

    -- v1 ctx：herdr: 触发，绑定 buffer（her1:p2）→ current 标记与最高分
    local cur_items = fetch_items({
      line = "herdr:her",
      keyword = "her",
      cursor = { 0, 9 },
      bufnr = bound_buf,
    })
    assert.truthy(
      cur_items ~= nil and cur_items.items ~= nil and #cur_items.items == 2,
      "agents 适配层：herdr: 触发出候选"
    )
    local by_id = {}
    for _, it in ipairs(cur_items.items) do
      by_id[it.label] = it
    end
    assert.truthy(by_id["her1:p2"] ~= nil and by_id["her7:p9"] ~= nil, "agents 适配层：label = pane_id")
    assert.truthy(
      by_id["her1:p2"].insertText == "her1:p2 (repo-a:opencode)"
        and by_id["her7:p9"].insertText == "her7:p9 (repo-b:codex)",
      "agents 适配层：insertText = pane_id + (workspace:kind)，与候选显示一致"
    )
    assert.truthy(
      by_id["her1:p2"].labelDetails ~= nil
        and by_id["her1:p2"].labelDetails.detail == " (repo-a:opencode)"
        and by_id["her7:p9"].labelDetails ~= nil
        and by_id["her7:p9"].labelDetails.detail == " (repo-b:codex)",
      "agents 适配层：labelDetails.detail 渲染 (workspace:kind)（blink 默认 label 组件直接拼接）"
    )
    assert.truthy(
      by_id["her1:p2"].detail == "idle · current",
      "agents 适配层：detail = status，当前 agent 追加 · current（kind 移入 labelDetails）"
    )
    assert.truthy(by_id["her7:p9"].detail == "working", "agents 适配层：非当前 agent 无 current 标记")
    local f1 = by_id["her1:p2"].filterText or ""
    assert.truthy(
      f1:find("repo-a", 1, true)
        and f1:find("opencode", 1, true)
        and f1:find("opencode: fixing bug", 1, true)
        and f1:find("/repo/a", 1, true),
      "agents 适配层：filterText 含 workspace/kind/title/cwd"
    )
    -- 无 name 的 agent 也必须带 title/cwd（表构造里 name=nil 会形成 ipairs 空洞）
    local f2 = by_id["her7:p9"].filterText or ""
    assert.truthy(
      f2:find("repo-b", 1, true) and f2:find("codex fix bug", 1, true) and f2:find("/repo/b", 1, true),
      "agents 适配层：filterText 对无 name 的 agent 仍含 workspace/title/cwd"
    )
    assert.truthy(
      (by_id["her1:p2"].documentation.value or ""):find("main", 1, true) ~= nil
        and (by_id["her7:p9"].documentation.value or ""):find("/repo/b", 1, true) ~= nil,
      "agents 适配层：documentation 汇总 name/cwd（缺省字段不显示）"
    )
    local doc1 = by_id["her1:p2"].documentation.value or ""
    assert.truthy(
      doc1:find("repo-a", 1, true) ~= nil and doc1:find("ws1", 1, true) ~= nil,
      "agents 适配层：documentation 含 workspace 名与 id"
    )
    assert.truthy(
      by_id["her1:p2"].score_offset == 10 and by_id["her7:p9"].score_offset == 0,
      "agents 适配层：score_offset current(10) > 同 tab(5)/其他(0)"
    )

    -- 同 tab 加分：无绑定 buffer + HERDR_TAB_ID = t2 → her7:p9 得 5、her1:p2 得 0
    vim.env.HERDR_TAB_ID = "t2"
    local tab_items = fetch_items({
      line = "herdr:he",
      keyword = "he",
      cursor = { 0, 8 },
      bufnr = plain_buf,
    })
    local tab_by_id = {}
    for _, it in ipairs(tab_items.items) do
      tab_by_id[it.label] = it
    end
    assert.truthy(
      tab_by_id["her7:p9"].score_offset == 5 and tab_by_id["her1:p2"].score_offset == 0,
      "agents 适配层：同 tab 得 5（无 current 绑定时按 HERDR_TAB_ID）"
    )

    -- 前缀不匹配/大小写敏感 → 空；宽松 xherdr: 触发
    local http_items = fetch_items({
      line = "http:her",
      keyword = "her",
      cursor = { 0, 8 },
      bufnr = bound_buf,
    })
    assert.truthy(http_items ~= nil and #http_items.items == 0, "agents 适配层：非 herdr: 前缀回空")
    local case_items = fetch_items({
      line = "Herdr:h",
      keyword = "h",
      cursor = { 0, 7 },
      bufnr = bound_buf,
    })
    assert.truthy(case_items ~= nil and #case_items.items == 0, "agents 适配层：前缀判定大小写敏感")
    local loose_items = fetch_items({
      line = "xherdr:h",
      keyword = "h",
      cursor = { 0, 8 },
      bufnr = bound_buf,
    })
    assert.truthy(loose_items ~= nil and #loose_items.items == 2, "agents 适配层：宽松匹配 xherdr: 也触发")
    -- pane_id 自身含 ":"（herdr:her1:）→ 仍应出候选，而不是把菜单关掉
    local second_colon = fetch_items({
      line = "herdr:her1:",
      keyword = "",
      cursor = { 0, 11 },
      bufnr = bound_buf,
    })
    assert.truthy(
      second_colon ~= nil and #second_colon.items == 2,
      "agents 适配层：pane_id 自带的 : 不关闭候选"
    )

    -- 还原：环境变量、ttl、执行器、缓存与测试 buffer
    utils.set_exec_async(nil)
    agents._reset()
    agents._ttl_ms = saved_ttl
    vim.env.HERDR_ENV = saved_env
    vim.env.HERDR_TAB_ID = saved_tab
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
    vim.api.nvim_buf_delete(bound_buf, { force = true })
    vim.api.nvim_buf_delete(plain_buf, { force = true })
  end

  -- ---------------------------------------------------------------------------
  -- workspace 域限定：HERDR_WORKSPACE_ID 可解析时候选仅限同 workspace 的 agent
  -- （跨 workspace 不出候选），(workspace:kind) 角标 / display / 打分对保留条目
  -- 完全不变；未设置（nvim 不在 herdr 内）时 fail-open 不过滤。数据层不受影响
  --（同 agent 列表在不同 env 下各自过滤）
  -- ---------------------------------------------------------------------------
  local function run_workspace_scope_tests()
    local agents = require("herder-agents.agents")
    local adapter = require("herder-agents.completion.agents")

    local saved_env = vim.env.HERDR_ENV
    local saved_tab = vim.env.HERDR_TAB_ID
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    local saved_ttl = agents._ttl_ms

    -- fixture 同主套件：her1:p2 → ws1(repo-a:opencode)，her7:p9 → ws2(repo-b:codex)
    local fake_json = vim.json.encode({
      result = {
        agents = {
          {
            pane_id = "her1:p2",
            agent = "opencode",
            agent_status = "idle",
            name = "main",
            cwd = "/repo/a",
            tab_id = "t1",
            workspace_id = "ws1",
          },
          {
            pane_id = "her7:p9",
            agent = "codex",
            agent_status = "working",
            cwd = "/repo/b",
            tab_id = "t2",
            workspace_id = "ws2",
          },
        },
      },
    })
    local ws_json = vim.json.encode({
      result = {
        workspaces = {
          { workspace_id = "ws1", label = "repo-a" },
          { workspace_id = "ws2", label = "repo-b" },
        },
      },
    })
    utils.set_exec_async(function(argv, on_done)
      if argv[2] == "workspace" then
        on_done({ code = 0, stdout = ws_json, stderr = "" })
      else
        on_done({ code = 0, stdout = fake_json, stderr = "" })
      end
    end)

    vim.env.HERDR_ENV = "1"
    agents._reset()
    agents.list(function() end) -- 预热缓存（数据层全量：两条 agent 都在缓存里）

    local source = adapter.new({})
    local bound_buf = vim.api.nvim_create_buf(false, true)
    vim.b[bound_buf].pane_id = "her1:p2"
    local function fetch_items(ctx)
      local res = nil
      source:get_completions(ctx, function(r)
        res = r
      end)
      return res and res.items or {}
    end
    local by_label = function(items)
      local map = {}
      for _, it in ipairs(items) do
        map[it.label] = it
      end
      return map
    end

    -- A) HERDR_WORKSPACE_ID = ws1：跨 workspace 的 her7:p9 不出候选；
    --    保留条目的 (workspace:kind) 角标与 current 打分完全不变
    vim.env.HERDR_WORKSPACE_ID = "ws1"
    local ws1_items = by_label(fetch_items({
      line = "herdr:her",
      keyword = "her",
      cursor = { 0, 9 },
      bufnr = bound_buf,
    }))
    assert.truthy(
      ws1_items["her1:p2"] ~= nil and ws1_items["her7:p9"] == nil,
      "workspace 域限定：HERDR_WORKSPACE_ID 可解析时候选仅限同 workspace（异 workspace 不出候选）"
    )
    assert.truthy(
      ws1_items["her1:p2"].insertText == "her1:p2 (repo-a:opencode)"
        and ws1_items["her1:p2"].labelDetails ~= nil
        and ws1_items["her1:p2"].labelDetails.detail == " (repo-a:opencode)",
      "workspace 域限定：保留条目的 (workspace:kind) 角标不变"
    )
    assert.truthy(ws1_items["her1:p2"].score_offset == 10, "workspace 域限定：保留条目的 current 打分不变")

    -- B) HERDR_WORKSPACE_ID = ws2：另一侧同理（过滤跟着 env 走，缓存不回存）
    vim.env.HERDR_WORKSPACE_ID = "ws2"
    local ws2_items = by_label(fetch_items({
      line = "herdr:her",
      keyword = "her",
      cursor = { 0, 9 },
      bufnr = bound_buf,
    }))
    assert.truthy(
      ws2_items["her7:p9"] ~= nil and ws2_items["her1:p2"] == nil,
      "workspace 域限定：切换 env 后过滤跟随（另一 workspace 的 agent 出候选）"
    )

    -- C) env 未设置：fail-open 不过滤，两条 agent 都出候选
    vim.env.HERDR_WORKSPACE_ID = nil
    local open_items = by_label(fetch_items({
      line = "herdr:her",
      keyword = "her",
      cursor = { 0, 9 },
      bufnr = bound_buf,
    }))
    assert.truthy(
      open_items["her1:p2"] ~= nil and open_items["her7:p9"] ~= nil,
      "workspace 域限定：HERDR_WORKSPACE_ID 未设置时不过滤（fail-open）"
    )

    utils.set_exec_async(nil)
    agents._reset()
    agents._ttl_ms = saved_ttl
    vim.env.HERDR_ENV = saved_env
    vim.env.HERDR_TAB_ID = saved_tab
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
    vim.api.nvim_buf_delete(bound_buf, { force = true })
  end
  it("herdr: 提及补全", function()
    run_agent_completion_tests()
  end)
  it("herdr: 提及补全 workspace 域限定", function()
    run_workspace_scope_tests()
  end)
end)
