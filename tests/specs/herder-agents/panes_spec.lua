-- panes lookup / 中断按键（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("panes lookup / 中断按键", function()
  it("panes lookup / 中断按键", function()
    local utils = require("herder-agents.utils")
    -- 本段 fixture 无 workspace_id 字段（域限定专测见下方独立 it）：显式关掉
    -- HERDR_WORKSPACE_ID 保证确定性 —— ambient shell 可能带着，开着会把本段
    -- 所有 pane 候选滤空（fail-open 语义下未设置即不过滤）
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = nil
    local argv_log = {} -- 原单文件内与上一段共享的记录表；本段只写入不读取

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
    assert.truthy(#send_keys_log == 1 and send_keys_log[1].key == "esc", "opencode 中断立即发出第一个 esc")
    local seq_done = vim.wait(2000, function()
      return #send_keys_log >= 2
    end)
    assert.truthy(seq_done, "opencode 中断序列补发第二个 esc（defer 间隔发送）")
    assert.truthy(
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
    assert.truthy(#send_keys_log == 1 and send_keys_log[1].key == "esc", "omp 单键中断不变（仍是一个 esc）")

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
    assert.truthy(
      reused ~= nil and reused.pane_id == "p-live",
      "现场形态：lookup 收编自定义 label 的 agent pane（有 session 优先于裸 TUI）"
    )

    -- toggle：不 split 第二个实例，而是放大复用的 pane（同 tab 无需切 tab）
    live_clear()
    panes.toggle("opencode")
    assert.truthy(not saw(live_log, is_split), "现场形态：toggle 不再 split 新实例")
    assert.truthy(
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
    assert.truthy(
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
    assert.truthy(
      panes.lookup("opencode").pane_id == "p-oc1",
      "跨 tab 同路径：lookup 复用 t1 的 opencode pane（跳过无 cwd / 异路径候选）"
    )
    xtab_clear()
    panes.toggle("opencode")
    assert.truthy(
      saw(xtab_log, function(argv)
        return argv[2] == "tab" and argv[3] == "focus" and argv[4] == "t1"
      end),
      "跨 tab 同路径：toggle 切换焦点到 agent 所在 tab"
    )
    assert.truthy(
      saw(xtab_log, function(argv)
        return argv[2] == "pane" and argv[3] == "zoom" and vim.tbl_contains(argv, "p-oc1")
      end),
      "跨 tab 同路径：toggle 放大复用的 pane"
    )
    assert.truthy(not saw(xtab_log, is_split), "跨 tab 同路径：toggle 不再 split 第二个实例")

    -- ①级优先：当前 tab 已有 label 命中的 pane（即使 cwd 不同）时不跨 tab、
    -- 且保持原 zoom-toggle 语义（layout --current + zoom 当前 pane，不 tab focus）
    local intab_panes = {
      { label = "opencode", tab_id = "t2", pane_id = "p-in-tab", cwd = "/elsewhere" },
      { label = "opencode", tab_id = "t1", pane_id = "p-oc1", cwd = cur_cwd },
    }
    local intab_exec, intab_log, intab_clear = mk_fake(intab_panes, "t2", "p-nvim2")
    utils.set_exec(intab_exec)
    assert.truthy(
      panes.lookup("opencode").pane_id == "p-in-tab",
      "当前 tab 的同名 pane 优先于跨 tab / agent 匹配"
    )
    intab_clear()
    panes.toggle("opencode")
    assert.truthy(not saw(intab_log, is_split), "当前 tab 同名 pane：toggle 不 split")
    assert.truthy(saw(intab_log, function(argv)
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
    assert.truthy(panes.lookup("opencode").pane_id == "p-labeled", "label 命中优先于 agent 检测命中")

    -- 误收编防护：异 cwd 的 agent pane、同 cwd 但不同 agent（codex）都不命中
    local neg_panes = {
      {
        tab_id = "t9",
        pane_id = "p-far",
        cwd = "/somewhere-else",
        agent = "opencode",
        agent_session = { value = "s9" },
      },
      { tab_id = "t2", pane_id = "p-codex", cwd = cur_cwd, agent = "codex", agent_session = { value = "s2" } },
      { label = "opencode", tab_id = "t9", pane_id = "p-oc9", cwd = "/somewhere-else" },
    }
    utils.set_exec(mk_fake(neg_panes, "t2", "p-nvim2"))
    assert.truthy(panes.lookup("opencode") == nil, "异 cwd / 异 agent 的 pane 不被收编，lookup 返回 nil")

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
    assert.truthy(split_n == 1, "全新环境：一次 toggle 恰好 split 一次（无重复创建路径）")
    -- 模拟 split+rename 落地后的世界（实测 rename 立即反映到 pane list）：
    -- 新 nvim 进程（无任何内存态）按 ho 应直接接管该 pane
    table.insert(world, { label = "opencode", tab_id = "t2", pane_id = "p-created", cwd = cur_cwd })
    fresh_clear()
    panes.toggle("opencode")
    assert.truthy(not saw(fresh_log, is_split), "连续/重启后：接管既有 pane，不再 split")
    assert.truthy(
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
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
  end)

  -- ---------------------------------------------------------------------------
  -- find_tool_pane workspace 域限定：HERDR_WORKSPACE_ID 可解析时候选仅限同
  -- workspace 的 pane（三级匹配统一预过滤，①级当前 tab label 同样受限 —— 跨
  -- workspace 的同名/同 cwd pane 不再被收编，同名 workspace 跨 tab 复用保持）；
  -- 未设置时 fail-open 不过滤（原行为）
  -- ---------------------------------------------------------------------------
  it("find_tool_pane workspace 域限定", function()
    local utils = require("herder-agents.utils")
    local panes = require("herder-agents.panes")

    local saved_env = vim.env.HERDR_ENV
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_ENV = "1"
    local cur_cwd = vim.fn.getcwd()

    -- 假执行器：pane list 条目带 workspace_id；当前 tab 恒为 t2；split 回固定新 id
    local mk_ws_fake = function(pane_tbl)
      local log = {}
      local exec = function(argv)
        table.insert(log, argv)
        if argv[2] == "pane" and argv[3] == "current" then
          return {
            code = 0,
            stdout = vim.json.encode({ result = { pane = { tab_id = "t2", pane_id = "p-nvim" } } }),
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
      return exec, log
    end
    local saw = function(log, pred)
      for _, argv in ipairs(log) do
        if pred(argv) then
          return true
        end
      end
      return false
    end
    local is_split = function(argv)
      return argv[2] == "pane" and argv[3] == "split"
    end

    -- (a) env 可解析：异 workspace 的同名 pane 全部落空（①级当前 tab label、
    --     ②级跨 tab 同 cwd 同 label 都被预过滤），同 workspace 跨 tab ②级照常命中
    local mixed_panes = {
      -- ①级形状（当前 tab t2 label 命中）但 workspace 不同 → 预过滤掉
      { label = "opencode", tab_id = "t2", pane_id = "p-w2-curtab", cwd = "/elsewhere", workspace_id = "w2" },
      -- ②级形状（跨 tab 同 cwd 同 label）但 workspace 不同 → 预过滤掉
      { label = "opencode", tab_id = "t1", pane_id = "p-w2-xtab", cwd = cur_cwd, workspace_id = "w2" },
      -- ②级：同 workspace 跨 tab 同 cwd 同 label → 保留并命中
      { label = "opencode", tab_id = "t1", pane_id = "p-w1-xtab", cwd = cur_cwd, workspace_id = "w1" },
    }
    vim.env.HERDR_WORKSPACE_ID = "w1"
    utils.set_exec(mk_ws_fake(mixed_panes))
    local hit = panes.lookup("opencode")
    assert.truthy(
      hit ~= nil and hit.pane_id == "p-w1-xtab",
      "workspace 域限定：跨 tab 复用只发生在同 workspace（异 workspace 同名 pane 不命中）"
    )

    -- 只剩异 workspace 候选时：三级全落空 → lookup nil，toggle 走 split 新建
    local only_w2_exec, only_w2_log = mk_ws_fake({
      { label = "opencode", tab_id = "t1", pane_id = "p-w2-only", cwd = cur_cwd, workspace_id = "w2" },
    })
    utils.set_exec(only_w2_exec)
    assert.truthy(
      panes.lookup("opencode") == nil,
      "workspace 域限定：仅剩异 workspace 候选时 lookup 返回 nil"
    )
    panes.toggle("opencode")
    assert.truthy(
      saw(only_w2_log, is_split),
      "workspace 域限定：三级全落空后 toggle 另 split 新实例（不收编异 workspace pane）"
    )

    -- 缺 workspace_id 字段的 pane 同样视为异 workspace（预过滤丢弃）
    utils.set_exec(mk_ws_fake({
      { label = "opencode", tab_id = "t1", pane_id = "p-no-ws", cwd = cur_cwd },
    }))
    assert.truthy(
      panes.lookup("opencode") == nil,
      "workspace 域限定：缺 workspace_id 的候选在 env 可解析时不命中"
    )

    -- (b) env 未设置：fail-open 不过滤 —— 异 workspace / 缺字段的同 cwd pane 仍命中（原行为）
    vim.env.HERDR_WORKSPACE_ID = nil
    utils.set_exec(mk_ws_fake({
      { label = "opencode", tab_id = "t1", pane_id = "p-w2-open", cwd = cur_cwd, workspace_id = "w2" },
    }))
    local open_hit = panes.lookup("opencode")
    assert.truthy(
      open_hit ~= nil and open_hit.pane_id == "p-w2-open",
      "workspace 域限定：HERDR_WORKSPACE_ID 未设置时不过滤（fail-open，异 workspace 仍命中）"
    )

    utils.set_exec(nil)
    utils.set_exec_async(nil)
    if saved_env then
      vim.env.HERDR_ENV = saved_env
    else
      vim.env.HERDR_ENV = nil
    end
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
  end)
end)
