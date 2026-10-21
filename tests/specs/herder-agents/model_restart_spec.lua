-- 终端复位 / 模型切换 / 工具切换（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

describe("终端复位 / 模型切换 / 工具切换", function()
  it("终端复位 / 模型切换 / 工具切换", function()
    local utils = require("herder-agents.utils")
    local config_mod = require("herder-agents.config")
    local panes = require("herder-agents.panes")
    -- 本文件 fixture pane 均无 workspace_id 字段（域限定行为在 panes_spec 专测）：
    -- 显式关掉 HERDR_WORKSPACE_ID 保证确定性 —— ambient shell 可能带着，开着
    -- find_tool_pane 的域预过滤会把 fixture pane 全部滤空、走错分支
    local saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = nil
    local argv_log = {} -- 原单文件内与共享段的记录表；本段仅在假执行器里写入、不读取

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
    assert.truthy(
      utils.reset_pane_terminal("p-x") == true,
      "终端复位经 pane send-text 发送，以退出码判定"
    )
    assert.truthy(
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

    assert.truthy(
      vim.deep_equal(
        model_restart._flatten_models({ openai = { "gpt-5.4" }, anthropic = { "opus", "sonnet" } }),
        { "anthropic/opus", "anthropic/sonnet", "openai/gpt-5.4" }
      ),
      "两级 models 平铺为排序的 provider/model 列表"
    )
    local sp, sm = model_restart._split_entry("zhipuai/glm-5.3#high")
    assert.truthy(
      sp == "zhipuai" and sm == "glm-5.3#high",
      "候选解析出 provider 与 model（#variant 留在 model 内）"
    )
    assert.truthy(
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
    assert.truthy(model_restart._opencode_session_id(oc_pane) == "ses_hit", "opencode 会话按标题精确匹配")
    oc_pane.terminal_title_stripped = "OC | 不存在的标题"
    assert.truthy(model_restart._opencode_session_id(oc_pane) == "ses_hit", "标题无匹配时取最新会话")

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
    assert.truthy(model_restart.switch("opencode") == true, "models 已配置时 switch 受理")
    local api_line = nil
    for _, e in ipairs(mr_log) do
      if e:find("^api:") then
        api_line = e
      end
    end
    assert.truthy(
      api_line ~= nil
        and api_line:find("api:/api/session/ses_hit/model,--data,", 1, true) ~= nil
        and api_line:find('"id":"glm', 1, true)
        and api_line:find('"providerID":"zhipuai-coding-plan"', 1, true)
        and api_line:find('"variant":"high"', 1, true),
      "api 原地切换：post session model（#variant 拆为独立字段，会话按标题定位）"
    )
    assert.truthy(not vim.tbl_contains(mr_log, "send-text:/quit"), "原地切换不发送 /quit")
    assert.truthy(#vim.tbl_filter(function(e)
      return e:find("^run:")
    end, mr_log) == 0, "原地切换不触发 pane run 重启")

    -- api 失败（如未知模型）：报错退出且无其它副作用
    mr_api_code = 1
    mr_log = {}
    assert.truthy(model_restart.switch("opencode") == true, "api 失败场景 switch 仍受理")
    assert.truthy(#vim.tbl_filter(function(e)
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
    assert.truthy(model_restart.switch("opencode") == true, "重启路径 switch 受理")
    local mr_done = vim.wait(8000, function()
      for _, e in ipairs(mr_log) do
        if e:find("^run:") then
          return true
        end
      end
      return false
    end)
    assert.truthy(mr_done, "切换流程走完 退出→重启（run 已发出）")
    local quit_sent, run_line = false, nil
    for _, e in ipairs(mr_log) do
      if e == "send-text:/quit" then
        quit_sent = true
      end
      if e:find("^run:") then
        run_line = e
      end
    end
    assert.truthy(quit_sent, "优雅退出先发送 quit_cmd（默认 /quit）")
    assert.truthy(vim.tbl_contains(mr_log, "send-keys:enter"), "quit_cmd 后补回车提交")
    assert.truthy(
      run_line == "run:p-oc,opencode,--session,ses_hit",
      "pane run 按模板重启（含捕获的会话 id）"
    )
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
    assert.truthy(
      reset_idx ~= nil and run_idx ~= nil and reset_idx < run_idx,
      "重启前先发终端复位载荷（先于 pane run）"
    )
    assert.truthy(
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

    assert.truthy(panes.replace("codex", "opencode") == true, "旧 agent 已退出时直接走同 pane 重启分支")
    local sw_done = vim.wait(4000, function()
      for _, e in ipairs(sw_log) do
        if e:sub(1, 4) == "run:" then
          return true
        end
      end
      return false
    end)
    assert.truthy(sw_done, "切换流程走到 pane run 启动新工具")
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
    assert.truthy(
      sw_reset_idx ~= nil and sw_run_idx ~= nil and sw_reset_idx < sw_run_idx,
      "工具切换：终端复位载荷先于启动命令发出"
    )
    assert.truthy(
      sw_clear_idx ~= nil and sw_reset_idx < sw_clear_idx and sw_clear_idx < sw_run_idx,
      "工具切换：复位后、启动前再补一次 ctrl+c 清行"
    )
    assert.truthy(sw_run_line == "run:p-cx,opencode", "启动命令原样发出（opencode 未与残留字节粘连）")
    if saved_ws then
      vim.env.HERDR_WORKSPACE_ID = saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
    utils.set_exec(nil)
    utils.set_exec_async(nil)
  end)
end)
