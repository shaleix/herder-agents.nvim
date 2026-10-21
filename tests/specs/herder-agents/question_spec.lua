-- agent 提问表单（由 旧 smoke 套件 迁移；plenary spec，仿 neogit tests/specs）

-- 独立实例基线：原单文件套件由 plugin 段先 setup（命令注册、默认不绑键）；
-- plenary 每个 spec 一个新 nvim 实例，这里自建同样基线。
vim.g.mapleader = " "
require("herder-agents").setup({ tools = { mycli = { title = " My CLI Chat " } } })

describe("agent 提问表单", function()
  local utils = require("herder-agents.utils")
  local cfg = require("herder-agents.config")
  local delivery = require("herder-agents.delivery")

  -- ---------------------------------------------------------------------------
  -- agent 提问表单（llm.lua + question.lua，ADR-0002）：全 headless、假执行器；
  -- ui/question_form.lua 由并行 lane 实现 —— 这里用 package.preload stub。
  -- ---------------------------------------------------------------------------
  local function run_question_tests()
    local llm = require("herder-agents.llm")
    local question_mod = require("herder-agents.question")

    -- 本文件 fixture pane 均无 workspace_id 字段（find_tool_pane 的域预过滤会把
    -- 它们全部滤空）：显式关掉 HERDR_WORKSPACE_ID 保证确定性（ambient shell
    -- 可能带着）；域限定行为本身在 panes_spec 专测
    local qa_saved_ws = vim.env.HERDR_WORKSPACE_ID
    vim.env.HERDR_WORKSPACE_ID = nil

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
    assert.truthy(vim.api.nvim_get_commands({}).AIQuestion ~= nil, ":AIQuestion 命令已注册")
    assert.truthy(
      cfg.options.llm.base_url == "https://api.deepseek.com"
        and cfg.options.llm.api_key_env == "DEEPSEEK_API_KEY"
        and cfg.options.llm.model == "deepseek-chat",
      "llm 默认 base_url / api_key_env / model（DeepSeek 开箱）"
    )
    assert.truthy(
      cfg.options.llm.timeout_ms == 30000 and cfg.options.llm.temperature == 0,
      "llm 默认 timeout_ms=30000 / temperature=0"
    )
    assert.truthy(
      cfg.options.llm.start_lines == 80 and cfg.options.llm.max_read_more == 2 and cfg.options.llm.retries == 1,
      "llm 默认 start_lines=80 / max_read_more=2 / retries=1"
    )
    assert.truthy(
      cfg.options.llm.enabled == true and cfg.options.llm.hint == nil and cfg.options.llm.auto_question == nil,
      "llm 默认 enabled 开启，hint/auto_question 已移除"
    )
    assert.truthy(
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
    assert.truthy(
      ask_obj ~= nil and ask_err == nil and ask_obj.hello == "world",
      "llm.ask 成功解码 choices[1].message.content"
    )
    local qcall = to_file_calls[1]
    assert.truthy(qcall ~= nil and qcall.argv[1] == "curl", "内置实现经 curl（exec_async_to_file 通道）")
    assert.truthy(qcall.timeout_ms == 15000, "timeout_ms 透传 exec_async_to_file（SIGKILL 兜底）")
    local qjoined = table.concat(qcall.argv, " ")
    assert.truthy(qjoined:find("/chat/completions", 1, true) ~= nil, "请求 OpenAI 兼容 /chat/completions")
    assert.truthy(qjoined:find("Authorization: Bearer test-key", 1, true) ~= nil, "携带 Authorization header")
    assert.truthy(
      qjoined:find("response_format", 1, true) ~= nil and qjoined:find("json_object", 1, true) ~= nil,
      "body 含 response_format=json_object"
    )
    assert.truthy(
      vim.tbl_contains(qcall.argv, "-m") and vim.tbl_contains(qcall.argv, "15"),
      "curl -m 应用层超时（秒）"
    )

    -- llm.ask 失败面：curl 非零 / HTTP 坏 JSON / content 坏 JSON
    utils.set_exec_to_file(function(argv, on_done)
      on_done({ code = 7, stdout = "", stderr = "connection refused" })
    end)
    ask_obj, ask_err = nil, nil
    llm.ask({ system = "s", user = "u" }, function(obj, err)
      ask_obj, ask_err = obj, err
    end)
    assert.truthy(
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
    assert.truthy(ask_obj == nil and type(ask_err) == "string", "HTTP 响应坏 JSON → nil + err")

    utils.set_exec_to_file(function(argv, on_done)
      on_done({ code = 0, stdout = vim.json.encode({ choices = { { message = { content = "{oops" } } } }), stderr = "" })
    end)
    ask_obj, ask_err = nil, nil
    llm.ask({ system = "s", user = "u" }, function(obj, err)
      ask_obj, ask_err = obj, err
    end)
    assert.truthy(ask_obj == nil and type(ask_err) == "string", "message.content 坏 JSON → nil + err")

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
    assert.truthy(
      ask_obj == nil and type(ask_err) == "string" and ask_err:find("DEEPSEEK_API_KEY", 1, true) ~= nil,
      "缺 api_key → nil + err（含 env 变量名）"
    )
    assert.truthy(key_probe_calls == 0, "缺 api_key 不起子进程")
    vim.env.DEEPSEEK_API_KEY = "test-key"

    -- adapter 覆盖（仿 utils.set_exec 注入惯例）
    llm.set_adapter(function(opts, cb)
      cb({ via = "adapter", user = opts.user }, nil)
    end)
    ask_obj, ask_err = nil, nil
    llm.ask({ system = "s", user = "usr2" }, function(obj, err)
      ask_obj, ask_err = obj, err
    end)
    assert.truthy(
      ask_obj ~= nil and ask_obj.via == "adapter" and ask_obj.user == "usr2",
      "set_adapter 覆盖内置实现"
    )
    llm.set_adapter(nil)

    -- ---------------------------------------------------------------------------
    -- llm 请求定制（extra_body / extra_headers / disable_thinking，仿 neogit ai_commit）
    -- ---------------------------------------------------------------------------
    assert.truthy(
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
    assert.truthy(
      eb ~= nil and eb.enable_thinking == false and eb.temperature == 0 and eb.response_format.type == "json_object",
      "extra_body 深合并进 -d body（内置字段保留）"
    )

    -- extra_body 嵌套表深合并（vLLM 的 chat_template_kwargs）
    body_argv_calls = {}
    cfg.options.llm.extra_body = { chat_template_kwargs = { enable_thinking = false } }
    llm.ask({ system = "s", user = "u" }, function() end)
    eb = req_body(body_argv_calls[1])
    assert.truthy(
      eb ~= nil and type(eb.chat_template_kwargs) == "table" and eb.chat_template_kwargs.enable_thinking == false,
      "extra_body 嵌套表（chat_template_kwargs）深合并"
    )

    -- extra_body 覆盖内置字段（用户赢）
    body_argv_calls = {}
    cfg.options.llm.extra_body = { temperature = 0.2 }
    llm.ask({ system = "s", user = "u" }, function() end)
    eb = req_body(body_argv_calls[1])
    assert.truthy(eb ~= nil and eb.temperature == 0.2, "extra_body 覆盖内置字段（temperature=0.2）")
    cfg.options.llm.extra_body = nil

    -- disable_thinking 厂商预设：按 base_url 明文 needle 依序匹配
    cfg.options.llm.disable_thinking = true
    local preset_cases = {
      {
        base = "http://127.0.0.1:11434",
        probe = function(b)
          return b.think == false
        end,
      },
      {
        base = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        probe = function(b)
          return b.enable_thinking == false
        end,
      },
      {
        base = "https://api.deepseek.com",
        probe = function(b)
          return type(b.thinking) == "table" and b.thinking.type == "disabled"
        end,
      },
      {
        base = "https://openrouter.ai/api/v1",
        probe = function(b)
          return type(b.reasoning) == "table" and b.reasoning.enabled == false
        end,
      },
      {
        base = "https://api.openai.com/v1",
        probe = function(b)
          return b.reasoning_effort == "minimal"
        end,
      },
    }
    for _, pc in ipairs(preset_cases) do
      body_argv_calls = {}
      cfg.options.llm.base_url = pc.base
      llm.ask({ system = "s", user = "u" }, function() end)
      local pb = req_body(body_argv_calls[1])
      assert.truthy(pb ~= nil and pc.probe(pb), "disable_thinking 预设注入：" .. pc.base)
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
    assert.truthy(
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
    assert.truthy(#warns == 1, "未知端点 warn 每会话仅一次（第二次调用静默）")
    utils.warn = saved_warn

    -- extra_body 与预设同时存在 → extra_body 赢（覆盖预设）
    body_argv_calls = {}
    cfg.options.llm.base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    cfg.options.llm.extra_body = { enable_thinking = true }
    llm.ask({ system = "s", user = "u" }, function() end)
    eb = req_body(body_argv_calls[1])
    assert.truthy(
      eb ~= nil and eb.enable_thinking == true,
      "extra_body 与 disable_thinking 预设同时存在 → extra_body 赢"
    )
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
    assert.truthy(
      vim.tbl_contains(body_argv_calls[1], "X-Tenant: team-a")
        and vim.tbl_contains(body_argv_calls[1], "TTL: 30")
        and hcount == 4,
      'extra_headers 追加 -H "k: v"（数字值 tostring，含内置共 4 个）'
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
    assert.truthy(hcount == 2, "未配置 extra_headers 时仅 Authorization/Content-Type 两个 -H")

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
        return {
          code = 0,
          stdout = (table.remove(read_pages, 1) or "agent asks: pick one? [1] yes [2] no"),
          stderr = "",
        }
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
    assert.truthy(
      #read_log == 2 and read_log[1] == 80 and read_log[2] == 160,
      "need_more → --lines 翻倍重读（80 → 160）"
    )
    -- system_prompt 语义（原始内容仍是唯一事实源）：编号进 label、question 不含自身
    -- 编号前缀、其余 verbatim 复制 —— 字符串断言（含 verbatim 措辞与编号前缀措辞）
    local qsys = adapter_log[1] and adapter_log[1].system or ""
    assert.truthy(
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
    assert.truthy(#form_specs == 1 and form_specs[1].mode == "form", "complete → form 表单")
    assert.truthy(
      type(form_specs[1].questions) == "table" and #form_specs[1].questions == 2 and form_specs[1].question == nil,
      "morph spec 携带 questions[]（2 题；不再有旧顶层 question 字段）"
    )
    assert.truthy(
      form_specs[1].questions[1].question == "Proceed?"
        and form_specs[1].questions[1].options[1] == "yes"
        and form_specs[1].questions[1].options[2] == "no",
      "morph spec 第 1 题逐字携带 question/options"
    )
    assert.truthy(
      form_specs[1].questions[1].multiple == false and form_specs[1].questions[1].suggested[1] == 1,
      "morph spec 第 1 题携带 multiple/suggested"
    )
    assert.truthy(
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
    assert.truthy(
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
    assert.truthy(
      dsys:find('"desc": string', 1, true) ~= nil
        and dsys:find("ONLY the recommendation note", 1, true) ~= nil
        and dsys:find("NEVER contains option content", 1, true) ~= nil
        and dsys:find('use "" when', 1, true) ~= nil
        and dsys:find("Never invent questions or options", 1, true) ~= nil,
      "system_prompt 携带 desc schema 行与规则措辞（说明文本/不含选项文本/缺省空串）"
    )
    assert.truthy(
      #form_specs == 1
        and form_specs[1].mode == "form"
        and form_specs[1].questions[1].desc == "➡️ 推荐 (a)：Docker，环境一致、回滚方便",
      "morph spec 第 1 题逐字携带 desc"
    )
    assert.truthy(
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
    assert.truthy(
      #adapter_log == 2 and adapter_log[2].system:find("desc 必须是 string", 1, true) ~= nil,
      "desc 非 string → 整体无效并重试（失败原因附 questions[k] desc 必须是 string）"
    )
    assert.truthy(
      form_specs[1] ~= nil and form_specs[1].mode == "form" and form_specs[1].questions[1].desc == "",
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
    assert.truthy(
      lsys:find('"label": string', 1, true) ~= nil
        and lsys:find("the question's own number in the excerpt", 1, true) ~= nil
        and lsys:find('use "" when the question carries no number', 1, true) ~= nil
        and lsys:find("Never invent questions or options", 1, true) ~= nil,
      "system_prompt 携带 label schema 行与规则措辞（原样复制标号/无标号归空串）"
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].label == "Q2",
      "morph spec 第 1 题逐字携带 label（validate 携带 → spec 自动携带）"
    )
    assert.truthy(
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
    assert.truthy(
      #adapter_log == 2 and adapter_log[2].system:find("label 必须是 string", 1, true) ~= nil,
      "label 非 string → 整体无效并重试（失败原因附 questions[k] label 必须是 string）"
    )
    assert.truthy(
      form_specs[1] ~= nil and form_specs[1].mode == "form" and form_specs[1].questions[1].label == "",
      "label 无效重试成功 → form 表单（重试轮缺省 label 归一空串）"
    )

    -- 2) 无效 JSON 重试 1 次后成功（重试 system 附上次失败原因；不重读终端）
    script = {
      "simulated bad json",
      { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = true } } },
    }
    form_specs = {}
    read_log = {}
    adapter_log = {}
    question_mod.ask()
    assert.truthy(#read_log == 1, "重试不重读终端（agent read 仅 1 次）")
    assert.truthy(#adapter_log == 2, "失败后重试 1 次（ask 共 2 次）")
    assert.truthy(
      adapter_log[2].system:find("simulated bad json", 1, true) ~= nil,
      "重试 system 附上次失败原因"
    )
    assert.truthy(
      form_specs[1] ~= nil and form_specs[1].mode == "form" and form_specs[1].questions[1].multiple == true,
      "重试成功出 form 表单"
    )

    -- 3) 两次失败 → fallback（raw_text 携带捕获文本）
    script = { "http 500", "still failing" }
    form_specs = {}
    question_mod.ask()
    assert.truthy(#form_specs == 1 and form_specs[1].mode == "fallback", "两次失败 → fallback 表单")
    assert.truthy(
      type(form_specs[1].raw_text) == "string" and #form_specs[1].raw_text > 0,
      "fallback 携带捕获文本"
    )

    -- 4) no_question → fallback；complete 但 questions 空数组/缺失视为 no_question
    script = { { status = "no_question" } }
    form_specs = {}
    question_mod.ask()
    assert.truthy(form_specs[1].mode == "fallback", "no_question → fallback 表单")
    script = { { status = "complete", questions = {} } }
    form_specs = {}
    question_mod.ask()
    assert.truthy(form_specs[1].mode == "fallback", "complete 且 questions 空数组视为 no_question → fallback")

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
    assert.truthy(#adapter_log == 2, "题内 suggested 越界 → 整体无效并重试")
    assert.truthy(form_specs[1].mode == "fallback", "无效重试后仍失败 → fallback")

    -- 4c) 阶段流：capture → extract → read_more "1/2" → complete 原位 morph（loading 恰一次）
    script = {
      { status = "need_more" },
      { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = false } } },
    }
    form_specs, stage_log, loading_handles = {}, {}, {}
    local lc0 = loading_calls
    question_mod.ask()
    assert.truthy(loading_calls == lc0 + 1, "ask 开场即 open_loading（恰一次）")
    assert.truthy(
      #stage_log == 3
        and stage_log[1].stage == "capture"
        and stage_log[1].detail == nil
        and stage_log[2].stage == "extract"
        and stage_log[2].detail == nil
        and stage_log[3].stage == "read_more"
        and stage_log[3].detail == "1/2",
      "阶段序列 capture → extract → read_more（detail 携带 N/M）"
    )
    assert.truthy(#form_specs == 1 and form_specs[1].mode == "form", "完成后原位 morph_to form 表单")

    -- 4d) 重试轮阶段：retry 携带上次失败原因
    script = {
      "simulated bad json",
      { status = "complete", questions = { { question = "Q?", options = { "a" }, multiple = true } } },
    }
    form_specs, stage_log = {}, {}
    question_mod.ask()
    assert.truthy(
      #stage_log == 3
        and stage_log[1].stage == "capture"
        and stage_log[2].stage == "extract"
        and stage_log[3].stage == "retry"
        and stage_log[3].detail == "simulated bad json",
      '重试轮 set_stage("retry") 且 detail 为上次失败原因'
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].multiple == true,
      "重试成功原位 morph form 表单"
    )

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
    assert.truthy(loading_calls == lc1 + 1, "capture 失败路径仍先 open_loading")
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text == "",
      "capture 失败 → morph fallback（raw_text 空文本）"
    )

    -- 5) 提交：表单回调 text → delivery 文本通道 send-text（原文逐行 + 括号粘贴）+ 提交键；
    --    qa1 已注册且 blocked —— 不允许出现 agent prompt（agent_blocked 拒收面）
    script = {
      {
        status = "complete",
        questions = { { question = "Approve?", options = { "allow", "deny" }, multiple = false, suggested = {} } },
      },
    }
    form_specs = {}
    question_mod.ask()
    assert.truthy(form_specs[1].mode == "form", "form 表单已打开（提交用例前置）")
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
    assert.truthy(q_sent_text ~= nil, "提交经 send-text（delivery 文本通道）")
    assert.truthy(
      q_sent_text:find("allow", 1, true) ~= nil and q_sent_text:find("custom note", 1, true) ~= nil,
      "send-text 携带原文逐行文本"
    )
    assert.truthy(
      q_sent_text:find("\27[200~", 1, true) ~= nil,
      "多行答案经括号粘贴编码（防逐行误提交）"
    )
    assert.truthy(q_sent_key == "enter", "提交键 enter 已发送")
    assert.truthy(not saw_prompt, "blocked 注册 agent 不走 agent prompt（agent_blocked 拒收面）")
    assert.truthy(cfg.options.delivery.agent_channel == true, "文本通道圈定已复原（不影响后续投递）")

    -- 5b) esc 取消：closed 句柄后迟到的 llm 回调不 morph、不开表单、不再 warn；
    --     closed 句柄上 set_stage / morph_to 均 no-op（UI 契约）
    local held_cb
    llm.set_adapter(function(opts, cb)
      held_cb = cb -- 挂起回调：模拟异步迟到投递
    end)
    script = {}
    form_specs, stage_log, loading_handles = {}, {}, {}
    question_mod.ask()
    assert.truthy(
      #loading_handles == 1 and loading_handles[1].closed == false,
      "esc 用例前置：loading 已开且未 closed"
    )
    assert.truthy(
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
    assert.truthy(#form_specs == 0, "esc 后迟到回调不 morph（不开表单）")
    assert.truthy(#esc_notify == 0, "esc 后迟到回调不再 warn/notify 打扰")
    loading_handles[1].set_stage("extract", "late")
    loading_handles[1].morph_to({ mode = "form" }, function() end)
    assert.truthy(#form_specs == 0 and #stage_log == 2, "closed 句柄 set_stage/morph_to 均 no-op")
    llm.set_adapter(script_adapter)

    -- ---------------------------------------------------------------------------
    -- 7) :AIQuestionDev —— 本地文件 / 当前 buffer 驱动提问表单（dev，提交不投递）
    -- ---------------------------------------------------------------------------
    local dev_cmds = vim.api.nvim_get_commands({})
    assert.truthy(dev_cmds.AIQuestionDev ~= nil, ":AIQuestionDev 命令已注册")
    assert.truthy(
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
    assert.truthy(loading_calls == dev_lc0 + 1, "fixture 模式同样开场 open_loading（恰一次）")
    assert.truthy(#form_specs == 1 and form_specs[1].mode == "form", "有效 fixture → morph form 表单")
    assert.truthy(
      type(form_specs[1].questions) == "table"
        and #form_specs[1].questions == 1
        and form_specs[1].questions[1].question == "Proceed?"
        and form_specs[1].questions[1].options[1] == "yes"
        and form_specs[1].questions[1].options[2] == "no"
        and form_specs[1].questions[1].multiple == false
        and form_specs[1].questions[1].suggested[1] == 1,
      "fixture morph spec questions[] 逐字段携带每题字段"
    )
    assert.truthy(
      #adapter_log == 0 and #read_log == 0,
      "fixture 模式跳过网络与终端（adapter 与 herdr read 均未被调用）"
    )

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
    assert.truthy(dev_bad_json_warn ~= nil, "坏 JSON fixture → warn 附解析原因")
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text == "{definitely not json",
      "坏 JSON fixture → fallback 表单（raw_text = 原文预览）"
    )
    assert.truthy(#submitted == 0, "坏 JSON fixture 不产生任何投递")

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
    assert.truthy(dev_bad_schema_warn ~= nil, "校验无效 fixture → warn 附失败原因")
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "fallback" and form_specs[1].raw_text:find("options", 1, true) ~= nil,
      "校验无效 fixture → fallback（原文预览）"
    )
    assert.truthy(#submitted == 0, "校验无效 fixture 不产生任何投递")
    vim.notify = dev_saved_notify

    -- 7d) 非 json 文件 = 全真：文件全文作为捕获文本（走注入 adapter），出 form 表单
    local dev_txt = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "agent asks: pick one?", "[1] yes [2] no" }, dev_txt)
    script =
      { { status = "complete", questions = { { question = "Pick?", options = { "yes", "no" }, multiple = false } } } }
    form_specs, adapter_log, stage_log, read_log = {}, {}, {}, {}
    dev_notes = {}
    vim.notify = function(msg)
      table.insert(dev_notes, tostring(msg))
    end
    question_mod.ask_dev(dev_txt)
    assert.truthy(
      #adapter_log == 1
        and adapter_log[1].user:find("agent asks: pick one?", 1, true) ~= nil
        and adapter_log[1].user:find("[1] yes [2] no", 1, true) ~= nil,
      "全真模式：文件全文作为捕获文本送 LLM（adapter 真调用一次）"
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Pick?",
      "全真模式 → form 表单"
    )
    assert.truthy(#read_log == 0, "全真模式不捕获 herdr 终端（文件顶替 capture）")
    local dev_stats_msg, dev_raw_msg
    for _, m in ipairs(dev_notes) do
      if m:find("AIQuestionDev", 1, true) and m:find("统计", 1, true) then
        dev_stats_msg = m
      end
      if m:find("原始 LLM JSON 响应", 1, true) then
        dev_raw_msg = m
      end
    end
    assert.truthy(
      dev_stats_msg ~= nil
        and dev_stats_msg:find("题数=1", 1, true) ~= nil
        and dev_stats_msg:find("read-more 轮数=0", 1, true) ~= nil
        and dev_stats_msg:find("重试次数=0", 1, true) ~= nil
        and dev_stats_msg:find("总耗时=", 1, true) ~= nil,
      "全真模式 :messages 携带统计（题数 / read-more 轮数 / 重试次数 / 总耗时）"
    )
    assert.truthy(
      dev_raw_msg ~= nil and dev_raw_msg:find("Pick?", 1, true) ~= nil,
      "全真模式 :messages 携带末轮原始 LLM JSON 响应全文"
    )

    -- 7e) 全真 read-more：轮次与 stage 流照常展示，但重发的仍是同一份文件全文
    script = {
      { status = "need_more" },
      { status = "complete", questions = { { question = "Again?", options = { "a" }, multiple = false } } },
    }
    form_specs, stage_log, adapter_log = {}, {}, {}
    question_mod.ask_dev(dev_txt)
    assert.truthy(
      #stage_log == 3
        and stage_log[1].stage == "capture"
        and stage_log[2].stage == "extract"
        and stage_log[3].stage == "read_more"
        and stage_log[3].detail == "1/2",
      "全真模式阶段流 capture → extract → read_more（detail 1/2）照常展示"
    )
    local dev_body1 = adapter_log[1] and adapter_log[1].user:match("<<<BEGIN>>>\n(.*)\n<<<END>>>")
    local dev_body2 = adapter_log[2] and adapter_log[2].user:match("<<<BEGIN>>>\n(.*)\n<<<END>>>")
    assert.truthy(
      #adapter_log == 2
        and dev_body1 ~= nil
        and dev_body1 == dev_body2
        and dev_body1:find("agent asks: pick one?", 1, true) ~= nil,
      "read-more 轮重发同一份文件内容（行数翻倍对文件无意义）"
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Again?",
      "全真 read-more 后 morph form 表单"
    )

    -- 7f) 全真重试照常：失败 → retry 阶段（附原因）→ 成功出 form
    script = {
      "dev simulated failure",
      { status = "complete", questions = { { question = "R?", options = { "a" }, multiple = false } } },
    }
    form_specs, stage_log, adapter_log = {}, {}, {}
    question_mod.ask_dev(dev_txt)
    assert.truthy(
      #adapter_log == 2 and stage_log[3].stage == "retry" and stage_log[3].detail == "dev simulated failure",
      "全真模式失败 → retry 阶段（detail 携带原因）"
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "R?",
      "全真重试成功 morph form 表单"
    )

    -- 7g) dev 提交：只打 info 日志（未投递）；假 exec 日志必须为空
    submitted = {}
    form_submit("yes\ndev note")
    assert.truthy(#submitted == 0, "AIQuestionDev 提交绝不投递（无 send-text / send-keys / agent prompt）")
    local dev_submit_msg
    for _, m in ipairs(dev_notes) do
      if m:find("提交文本（未投递）", 1, true) then
        dev_submit_msg = m
      end
    end
    assert.truthy(
      dev_submit_msg ~= nil
        and dev_submit_msg:find("yes", 1, true) ~= nil
        and dev_submit_msg:find("dev note", 1, true) ~= nil,
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
    assert.truthy(
      #form_specs == 1
        and form_specs[1].mode == "fallback"
        and form_specs[1].raw_text:find("no_question", 1, true) ~= nil,
      "无参数 + filetype json buffer → fixture 路径（no_question → fallback 原文）"
    )
    assert.truthy(#adapter_log == 0 and #read_log == 0, "json buffer fixture 不调用 LLM / 终端")

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
    assert.truthy(
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
    assert.truthy(
      #adapter_log == 1
        and adapter_log[1].user:find("buffer asks:", 1, true) ~= nil
        and adapter_log[1].user:find("[1] yes [2] no", 1, true) ~= nil,
      "无参数 + 非 json buffer → buffer 全文（逐行 join）作为捕获文本"
    )
    assert.truthy(
      #form_specs == 1 and form_specs[1].mode == "form" and form_specs[1].questions[1].question == "Buf?",
      "无参数 buffer 全真管线 → form 表单"
    )
    vim.cmd("enew!")

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
    if qa_saved_ws then
      vim.env.HERDR_WORKSPACE_ID = qa_saved_ws
    else
      vim.env.HERDR_WORKSPACE_ID = nil
    end
  end
  it("agent 提问表单", function()
    run_question_tests()
  end)
end)
