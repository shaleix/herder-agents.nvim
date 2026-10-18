-- agent 提问表单编排（extraction，CONTEXT.md / ADR-0002）：
--   :AIQuestion → panes.lookup 解析当前 tool 的 pane 目标（复用既有三级匹配）
--   → `herdr agent read <pane> --lines N --format text` 捕获终端输出
--   → llm.ask 提取标准问题 JSON（status + questions[] 多问题；每题
--     label/question/desc/options/multiple/suggested，extraction schema v2；
--     编号进 label 字段、question 不含自身的编号前缀）
--   → 全程 open_loading 骨架承载阶段流（"capture" / "extract" / "read_more" / "retry"），
--     完成后原位 morph_to 出表单（form / fallback 两态；esc 取消后句柄 QQC，
--     迟到的 llm 回调一律静默丢弃 —— 不 morph_to、不 warn）
--   → 提交文本经 delivery 文本通道送回（agent blocked 时 `herdr agent prompt`
--     会以 agent_blocked 拒收 —— 必须走 send-text + 括号粘贴 + 提交键，
--     不旁路直调 herdr，见 ADR-0002 §3）
--
-- 失败语义：
--   - 无效 JSON / HTTP 错误 → 重试 config.llm.retries 次，重试的 system 附上次失败原因
--   - status = need_more → 行数翻倍重读重提（read-more loop），上限 config.llm.max_read_more
--   - 仍失败 / no_question（含 complete 但 questions 空数组或缺失）/ api_key 缺失
--     → fallback 表单（原样捕获文本，手动作答）
--
-- 提示层：订阅 status.lua 轮询发出的 User AIAgentBlocked（不新建轮询），
-- vim.notify 提醒 :AIQuestion；config.llm.hint 可关。
-- 自动形态（llm.auto_question，默认关）：blocked/done 事件直接 auto_check
-- 全自动提取 —— 本地启发式预过滤、morph 前状态复查、失败完全静默，
-- 详见 M.auto_check / M.on_agent_state。
local M = {}

local config = require("herder-agents.config")
local utils = require("herder-agents.utils")
local llm = require("herder-agents.llm")

local function llm_cfg()
  return config.options.llm or {}
end

-- 最近一次 open_loading 的句柄（手动与 auto 入口共用记录）：auto_check 入口据
-- 此判断「已有 loading/表单开着」（上一个 handle 未 closed）→ 跳过本次自动触发
local last_handle = nil

local function open_loading_tracked()
  last_handle = require("herder-agents.ui.question_form").open_loading()
  return last_handle
end

-- 提取 system prompt（extraction schema v2：多问题）；fail_note 非空时附上次失败原因（重试轮）
local function system_prompt(fail_note)
  local lines = {
    "You convert terminal output into structured questions for the user.",
    "This is a fast, purely mechanical FORMAT CONVERSION: do NOT analyze,",
    "summarize, translate, correct, or reorder the content — every field is",
    "excerpt text moved verbatim (at most split across question/desc/options);",
    "when in doubt, copy exactly as written.",
    "Respond with ONLY one JSON object:",
    '{ "status": "complete" | "need_more" | "no_question",',
    '  "questions": [ { "label": string, "question": string, "desc": string,',
    '    "options": string[], "multiple": boolean, "suggested": number[] }, ... ],',
    '  "reason": string }',
    "Rules:",
    '- status "complete": the excerpt contains one or more questions addressed to the user;',
    "  extract ALL of them (1..N) in order, one array item per question:",
    "  question = the question text copied verbatim, character-for-character —",
    "  but WITHOUT its own numbering prefix: that number moves into label (an",
    '  excerpt "Q2 - 输入形态与双模式：…" becomes label "Q2" plus question',
    '  "输入形态与双模式：…");',
    "  apart from that one prefix, never remove, rewrite, or renumber anything,",
    "  BUT it must NOT contain the option texts: when options are enumerated",
    '  inline in the excerpt ("(a) ... (b) ...", "1) ... 2) ..."), move those',
    "  texts into the options array instead of duplicating them inside question;",
    "  options = the selectable answers copied verbatim (>= 1), never altered —",
    '  KEEP each option\'s original label prefix exactly as written ("(a)",',
    '  "b)", "[1]", "1." ...): those labels identify the options to the agent,',
    "  never drop or renumber them;",
    "  question and options MAY use markdown syntax (**bold**, `code`, lists)",
    "  — keep it as-is, the form renders markdown;",
    "  multiple = whether several options may be selected; suggested = 1-based",
    "  indexes of recommended options (empty array when none).",
    "  desc = ONLY the recommendation note attached to the question (lines",
    '  like "➡️ 推荐 (a): ..." or "Recommended: ..."): copied verbatim, MAY',
    "  use markdown, and NEVER contains option content (options live only in",
    '  the options array; a label mention like "(a)" inside the note stays',
    '  as-is); use "" when the excerpt has no recommendation note.',
    "  label = the question's own number in the excerpt, copied verbatim (\"Q2\",",
    '  "3", "问题三" ...); use "" when the question carries no number — the',
    "  number lives in label, never repeated inside question; label is reply",
    "  metadata only, never invent it;",
    "  Never invent questions or options.",
    '- status "need_more": a question may exist but the excerpt is truncated or too short;',
    "  more terminal history is needed.",
    '- status "no_question": the agent is not asking anything.',
  }
  if fail_note then
    table.insert(lines, "Previous attempt failed: " .. fail_note .. ". Return corrected JSON.")
  end
  return table.concat(lines, "\n")
end

-- 提取结果校验（schema v2，多问题）：
--   complete：questions 必须为非空数组；每题 question 非空 string、options >= 1 且全为
--            string、multiple 为 boolean、suggested（可选）索引对该题 options 均为合法
--            1-based、desc（可选）为 string（缺失/nil 归一 ""，非 string 视为无效）、
--            label（可选）为 string（缺失/nil 归一 ""，非 string 视为无效）
--            —— 任一题不满足 → 整个响应视为无效（nil + 原因，走重试/兜底链）
--   questions 为空数组或缺失：视为 no_question（直接 fallback，不重试）
--   need_more / no_question：只要求 status 字段本身
-- 返回规范化 table，或 nil + 失败原因
local function validate(obj)
  if type(obj) ~= "table" then
    return nil, "提取结果不是 JSON 对象"
  end
  local status = obj.status
  if status == "need_more" or status == "no_question" then
    return { status = status, reason = type(obj.reason) == "string" and obj.reason or nil }
  end
  if status ~= "complete" then
    return nil, "未知 status: " .. tostring(status)
  end
  if type(obj.questions) ~= "table" or #obj.questions == 0 then
    return { status = "no_question" } -- questions 空数组/缺失视为 no_question
  end
  local questions = {}
  for qi, q in ipairs(obj.questions) do
    if type(q) ~= "table" then
      return nil, "questions[" .. qi .. "] 不是对象"
    end
    if type(q.question) ~= "string" or not q.question:match("%S") then
      return nil, "questions[" .. qi .. "] 缺少非空 question"
    end
    local options = q.options
    if type(options) ~= "table" or #options == 0 then
      return nil, "questions[" .. qi .. "] 缺少 options 数组（>= 1）"
    end
    for i, opt in ipairs(options) do
      if type(opt) ~= "string" then
        return nil, "questions[" .. qi .. "].options[" .. i .. "] 不是 string"
      end
    end
    if type(q.multiple) ~= "boolean" then
      return nil, "questions[" .. qi .. "] multiple 必须是 boolean"
    end
    local desc = ""
    if q.desc ~= nil then
      if type(q.desc) ~= "string" then
        return nil, "questions[" .. qi .. "] desc 必须是 string"
      end
      desc = q.desc
    end
    local label = ""
    if q.label ~= nil then
      if type(q.label) ~= "string" then
        return nil, "questions[" .. qi .. "] label 必须是 string"
      end
      label = q.label
    end
    local suggested = {}
    if q.suggested ~= nil then
      if type(q.suggested) ~= "table" then
        return nil, "questions[" .. qi .. "] suggested 必须是索引数组"
      end
      for _, idx in ipairs(q.suggested) do
        if type(idx) ~= "number" or idx % 1 ~= 0 or idx < 1 or idx > #options then
          return nil, "questions[" .. qi .. "] suggested 索引不合法: " .. tostring(idx)
        end
        table.insert(suggested, idx)
      end
    end
    table.insert(questions, {
      question = q.question,
      desc = desc,
      label = label,
      options = options,
      multiple = q.multiple,
      suggested = suggested,
    })
  end
  return { status = "complete", questions = questions }
end

--- 捕获 agent 终端最近 lines 行（`herdr agent read`，--format text）；
--- 失败（非零退出 / 空输出）返回 nil
function M.capture(pane_id, lines)
  local r = utils.exec({
    "herdr",
    "agent",
    "read",
    pane_id,
    "--lines",
    tostring(lines),
    "--format",
    "text",
  })
  if r.code ~= 0 or r.stdout == "" then
    return nil
  end
  return r.stdout
end

--- 表单提交 → delivery 文本通道送回该 agent。
--- agent blocked 时 `herdr agent prompt` 会以 agent_blocked 拒收，必须走
--- send-text + 括号粘贴 + 提交键；这里复用 delivery 自身的 agent_channel=false
--- escape hatch（README 文档化开关）圈定【本次】投递走文本通道 —— deliver 的
--- 立即文本路径全程同步完成（send-text → send-keys → on_done），flip 在
--- on_done 即恢复，不影响其他并发投递，也不改 delivery 既有行为；队列语义
--- 原样保留（pane 消失 / 未就绪仍走排队与丢弃）
function M.submit(pane_id, tool, text)
  if not text or text == "" then
    return false
  end
  local delivery = require("herder-agents.delivery")
  local dcfg = config.options.delivery or {}
  local tool_cfg = (config.options.tools or {})[tool] or {}
  local saved = dcfg.agent_channel
  dcfg.agent_channel = false -- 本次强制文本通道（见上）
  local ok, res = pcall(delivery.deliver, pane_id, tool, text, {
    submit_key = "enter",
    paste_wrap = tool_cfg.paste_wrap == true,
    on_done = function()
      dcfg.agent_channel = saved -- 所有投递路径（含排队丢弃）都以 on_done 收尾
    end,
  })
  if not ok then
    dcfg.agent_channel = saved
    utils.err("answer delivery failed: " .. tostring(res))
    return false
  end
  return res
end

-- 公共编排（M.ask 与 M.ask_dev 全真模式共用）：loading 骨架句柄由调用方入场前
-- 创建，阶段打点与原位 morph 全走该句柄；唯一差异点是 capture_fn —— ask 捕获
-- herdr 终端（herdr agent read），dev 全真返回固定文件全文（read-more 轮原样重发）。
-- stats 记录编排过程（read-more 轮数 / 重试次数 / 末轮 LLM 响应 / 总耗时 ms），
-- 以第二参透传给 opts.open_form(spec, stats)（ask 的 open_form 忽略之）。
-- auto 触发的静默变体：opts.silent = true 时所有 fallback/warn 收场换成
-- handle.close()（不弹表单不打扰）；opts.morph_guard（可选）在 complete 的
-- morph 前调用，返回 false → 静默关骨架（auto 的「已回 working」复查用）
local function run_pipeline(opts)
  local cfg = llm_cfg()
  local handle = opts.handle
  local capture_fn = opts.capture_fn
  local uv = vim.uv or vim.loop
  local stats = opts.stats or {}
  local started = uv.hrtime()
  -- morph 统一走 open_form：morph 前盖总耗时戳（ask_dev 调优反馈用）
  local open_form = function(spec)
    stats.elapsed_ms = math.floor((uv.hrtime() - started) / 1e6 + 0.5)
    opts.open_form(spec, stats)
  end
  -- fallback 收场分流：silent（auto 触发）变体完全静默 —— 只关骨架，不弹
  -- fallback 表单、不 warn；手动路径行为不变（warn + fallback 表单）
  local fallback_form = function(spec, warn_msg)
    if opts.silent then
      handle.close()
      return
    end
    if warn_msg then
      utils.warn(warn_msg)
    end
    open_form(spec)
  end

  handle.set_stage("capture")
  local lines = cfg.start_lines or 80
  local raw_text = capture_fn(lines)
  if raw_text == nil then
    fallback_form({ mode = "fallback", raw_text = "" }, "herdr agent read 失败，直接打开 fallback 表单")
    return
  end

  -- 提取整体关闭：跳过 LLM，直接 fallback（escape hatch）
  if cfg.enabled == false then
    fallback_form({ mode = "fallback", raw_text = raw_text })
    return
  end
  local key_err = llm.api_key_error()
  if key_err then
    fallback_form({ mode = "fallback", raw_text = raw_text }, key_err .. "，直接打开 fallback 表单")
    return
  end

  handle.set_stage("extract")
  local retries_left = cfg.retries == nil and 1 or cfg.retries
  local read_more_left = cfg.max_read_more == nil and 2 or cfg.max_read_more
  local read_more_max = read_more_left
  local fail_note = nil

  local function step()
    llm.ask({
      system = system_prompt(fail_note),
      user = "Agent terminal excerpt (last "
        .. lines
        .. " lines):\n<<<BEGIN>>>\n"
        .. raw_text
        .. "\n<<<END>>>\nExtract all questions as specified.",
      timeout_ms = cfg.timeout_ms,
    }, function(obj, err)
      if handle.closed then
        return -- esc 已取消：迟到结果一律丢弃（不打扰，连 warn 都不发）
      end
      stats.raw = obj and vim.json.encode(obj) or nil
      stats.err = err
      local result, verr
      if err then
        verr = err
      else
        result, verr = validate(obj)
      end
      if result then
        if result.status == "complete" then
          -- morph 前复查（仅 auto 传入 morph_guard）：该 pane 状态已不在触发集
          -- （如已回 working）→ 静默关骨架不弹；复查失败按仍在触发集处理
          if opts.morph_guard and not opts.morph_guard() then
            handle.close()
            return
          end
          open_form({ mode = "form", questions = result.questions })
          return
        end
        if result.status == "need_more" and read_more_left > 0 then
          -- read-more loop：行数翻倍重读重提（判别式追读，上限 max_read_more）
          read_more_left = read_more_left - 1
          stats.read_more = (stats.read_more or 0) + 1
          lines = lines * 2
          handle.set_stage("read_more", (read_more_max - read_more_left) .. "/" .. read_more_max)
          raw_text = capture_fn(lines) or raw_text
          step()
          return
        end
        if result.status == "no_question" then
          fallback_form({ mode = "fallback", raw_text = raw_text })
          return
        end
        verr = "need_more 超出追读上限（" .. tostring(result.reason or "no reason") .. "）"
      end
      -- 失败：无效 JSON / HTTP 错误 / 追读耗尽 → retries 次重试（system 附上次失败原因）
      if retries_left > 0 then
        retries_left = retries_left - 1
        stats.retries = (stats.retries or 0) + 1
        fail_note = verr
        handle.set_stage("retry", verr)
        step()
        return
      end
      fallback_form(
        { mode = "fallback", raw_text = raw_text },
        "AIQuestion 提取失败（" .. tostring(verr) .. "），打开 fallback 表单"
      )
    end)
  end
  step()
end

--- :AIQuestion 入口：open_loading 骨架 → 捕获 → 提取 → 原位 morph_to 表单。
--- 阶段流（stage 枚举 + detail，文案收口在组件内）：
---   "capture" → "extract" → 每轮 "read_more"（detail "N/M"）→ 重试轮 "retry"（detail = 上次失败原因）
function M.ask()
  local tool = config.current_tool()
  -- 开场即弹 loading 骨架；句柄承载阶段打点与原位 morph（closed 后一律 no-op）
  local handle = open_loading_tracked()
  local pane = require("herder-agents.panes").lookup(tool)
  if not pane then
    handle.close()
    utils.err(tool .. " pane not found; toggle it first, then run :AIQuestion")
    return
  end

  -- 提交回调：delivery 文本通道送回（与旧 open(spec, on_submit) 完全同构）
  local on_submit = function(text)
    if M.submit(pane.pane_id, tool, text) == false then
      utils.err("answer 未能送达 " .. tool .. "（pane 可能已关闭）")
    end
  end

  -- 完成后原位 morph（closed 句柄上为 no-op：esc 取消后不再 morph/开表单）
  run_pipeline({
    handle = handle,
    open_form = function(spec)
      handle.morph_to(spec, on_submit)
    end,
    capture_fn = function(lines_n)
      return M.capture(pane.pane_id, lines_n)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- :AIQuestionDev —— 开发命令：本地文件 / 当前 buffer 顶替 agent 终端捕获，
-- 驱动同一套提问表单编排（弹窗内容测试与 LLM 提示词调优）。提交绝不投递 ——
-- 任何路径都不经 delivery / herdr 发送，只打 :messages 日志。
-- ---------------------------------------------------------------------------

-- dev 提交回调：仅打日志（未投递），表单窗口照常关闭
local function dev_on_submit(text)
  utils.info("[AIQuestionDev] 提交文本（未投递）:\n" .. text)
end

-- dev 调优反馈（全真模式）：末轮原始 LLM JSON 响应全文 + 统计（题数 / read-more
-- 轮数 / 重试次数 / 总耗时 ms，uv.hrtime 计时）全部打到 :messages；表单照常弹出
local function dev_open_form(handle)
  return function(spec, stats)
    stats = stats or {}
    if stats.raw then
      utils.info("[AIQuestionDev] 末轮原始 LLM JSON 响应:\n" .. stats.raw)
    elseif stats.err then
      utils.info("[AIQuestionDev] 末轮 LLM 失败: " .. stats.err)
    end
    utils.info(
      string.format(
        "[AIQuestionDev] 统计：题数=%d，read-more 轮数=%d，重试次数=%d，总耗时=%dms",
        spec.questions and #spec.questions or 0,
        stats.read_more or 0,
        stats.retries or 0,
        stats.elapsed_ms or 0
      )
    )
    handle.morph_to(spec, dev_on_submit)
  end
end

-- dev fixture（.json）：无网络、无重试（确定性输入，重试无信息量）：内容
-- vim.json.decode 后直接走 validate() —— 合法 → morph form（need_more /
-- no_question 无追读可言，fallback 原文预览）；decode / 校验失败 → warn 附原因
-- （原始内容也打到 :messages）→ fallback（原文预览）
local function ask_dev_fixture(content)
  local handle = open_loading_tracked()
  local open_form = function(spec)
    handle.morph_to(spec, dev_on_submit)
  end
  local ok, obj = pcall(vim.json.decode, content)
  if not ok then
    utils.warn(
      "[AIQuestionDev] fixture JSON 解析失败（"
        .. tostring(obj)
        .. "），打开 fallback 表单（原文见 :messages）"
    )
    utils.info(content)
    open_form({ mode = "fallback", raw_text = content })
    return
  end
  local result, verr = validate(obj)
  if result == nil then
    utils.warn(
      "[AIQuestionDev] fixture 校验无效（"
        .. tostring(verr)
        .. "），打开 fallback 表单（原文见 :messages）"
    )
    utils.info(content)
    open_form({ mode = "fallback", raw_text = content })
    return
  end
  local nq = result.questions and #result.questions or 0
  if result.status == "complete" then
    utils.info("[AIQuestionDev] fixture 校验通过：status=complete，题数=" .. nq)
    open_form({ mode = "form", questions = result.questions })
    return
  end
  utils.info(
    "[AIQuestionDev] fixture 校验通过：status="
      .. result.status
      .. "，题数="
      .. nq
      .. "，打开 fallback 表单"
  )
  open_form({ mode = "fallback", raw_text = content })
end

-- dev 全真模式（非 json）：文件 / buffer 全文作为捕获文本，走与 M.ask 完全相同的
-- 编排（llm.ask 真调用；read-more / 重试 / 兜底照常 —— read-more 轮重发的仍是同一
-- 份内容：文件就是全部信息，行数参数对文件无意义，轮次与 stage 流照常展示）
local function ask_dev_pipeline(content)
  local handle = open_loading_tracked()
  run_pipeline({
    handle = handle,
    open_form = dev_open_form(handle),
    capture_fn = function()
      return content ~= "" and content or nil
    end,
  })
end

--- :AIQuestionDev [file] 开发命令入口。
--- path 以 .json 结尾（或无参数且当前 buffer 判定为 json：buffer 名以 .json 结尾
--- 或 filetype == "json"）= LLM 响应 fixture；其他文件 / 无参数非 json buffer =
--- 全真管线；两种模式的提交均只打日志（dev_on_submit），绝不投递
function M.ask_dev(path)
  if path and path ~= "" then
    if vim.fn.filereadable(path) ~= 1 then
      utils.warn("[AIQuestionDev] 无法读取文件: " .. path)
      return
    end
    local content = table.concat(vim.fn.readfile(path), "\n")
    if path:match("%.json$") then
      ask_dev_fixture(content)
    else
      ask_dev_pipeline(content)
    end
    return
  end
  -- 无参数：当前 buffer 全文；buffer 名以 .json 结尾或 filetype == json → fixture
  local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  if vim.api.nvim_buf_get_name(0):match("%.json$") or vim.bo.filetype == "json" then
    ask_dev_fixture(content)
  else
    ask_dev_pipeline(content)
  end
end

--- AIAgentBlocked 提示（init.setup 订阅既有 User 事件；status.lua 轮询发出，
--- 这里不新建轮询）。config.llm.hint = false 关闭
function M.notify_blocked(data)
  if llm_cfg().hint == false then
    return
  end
  local who = (data and (data.tool or data.pane_id)) or "agent"
  utils.info(who .. " 在等答案，:AIQuestion 提取作答")
end

-- ---------------------------------------------------------------------------
-- auto 触发（llm.auto_question，默认关）：status 轮询发现 agent 进入
-- llm.auto_question_states → AIAgentBlocked / AIAgentDone User 事件
-- （init.setup 订阅路由，不新建轮询）→ M.auto_check。
-- 全链路静默语义：预过滤不过 / 上一个表单未关 / no_question / 提取失败 /
-- 追读耗尽 / morph 前复查出已回 working → 只关骨架，不弹 fallback、不 notify
-- ---------------------------------------------------------------------------

-- 本地启发式预过滤的提问特征（模块级导出，可测 / 可扩展）：命中任一即认为
-- 终端输出值得调 LLM 提取（纯构建/进度日志在此被静默拦下，零 LLM 开销）
M.question_hints = { "？", "?", "❓", "(a)", "(A)", "[1]", "1.", "选项", "options" }

--- 启发式预过滤：text 含任一提问特征（M.question_hints）即 true
function M.looks_like_question(text)
  if type(text) ~= "string" then
    return false
  end
  for _, hint in ipairs(M.question_hints) do
    if text:find(hint, 1, true) ~= nil then
      return true
    end
  end
  return false
end

-- morph 前复查的数据面：经 utils 通道（`herdr agent list`）取该 pane 的
-- agent_status；查询失败（exec 错 / 清单里没有该 pane）返回 nil
local function pane_agent_status(pane_id)
  local list = utils.herdr_json("agent", "list")
  local agents = list and list.result and list.result.agents
  if type(agents) ~= "table" then
    return nil
  end
  for _, a in ipairs(agents) do
    if a.pane_id == pane_id then
      return a.agent_status
    end
  end
  return nil
end

--- auto 触发入口（事件链：status_poll → AIAgentBlocked/AIAgentDone → 这里）。
--- 行为链：上一个 loading/表单未关（手动或上一次 auto）→ 跳过；捕获该 pane
--- 输出 → 本地启发式预过滤（不含提问特征静默返回，不调 LLM、不弹骨架）→
--- 通过才开 loading 骨架走与手动相同的提取编排；complete → morph 前复查该
--- pane 状态仍属触发集（已回 working → 静默关骨架不弹；复查 exec 失败按仍在
--- 触发集处理 —— 宁可多弹一次）；no_question / 提取失败 / 追读耗尽 → 完全
--- 静默（run_pipeline 的 silent 变体：关骨架收场，不弹 fallback 不 warn）
function M.auto_check(data, status)
  local cfg = llm_cfg()
  if not cfg.auto_question then
    return
  end
  local states = cfg.auto_question_states or {}
  if status and not vim.tbl_contains(states, status) then
    return
  end
  local pane_id = data and data.pane_id
  if not pane_id then
    return
  end
  -- ① 上一个 handle 未 closed → 已有 loading/表单开着，跳过（防叠窗）
  if last_handle and not last_handle.closed then
    return
  end
  -- ② 捕获 + 本地启发式预过滤：不含提问特征静默返回（不调 LLM、不弹骨架）
  local text = M.capture(pane_id, cfg.start_lines or 80)
  if not M.looks_like_question(text) then
    return
  end
  -- ③ 提取编排（loading 骨架照常）：silent = fallback/warn 全部换成静默关骨架
  local handle = open_loading_tracked()
  local tool = (data and data.tool) or config.current_tool()
  local on_submit = function(answer)
    if M.submit(pane_id, tool, answer) == false then
      utils.err("answer 未能送达 " .. tostring(tool) .. "（pane 可能已关闭）")
    end
  end
  run_pipeline({
    handle = handle,
    silent = true,
    open_form = function(spec)
      handle.morph_to(spec, on_submit)
    end,
    capture_fn = function(lines_n)
      return M.capture(pane_id, lines_n)
    end,
    -- morph 前复查：pane 已不在触发集（回 working 等）→ false → 静默关
    morph_guard = function()
      local st = pane_agent_status(pane_id)
      return st == nil or vim.tbl_contains(states, st)
    end,
  })
end

-- User 事件名 → agent 状态名（on_agent_state 路由用；payload.status 兜底）
local status_for_event = { AIAgentBlocked = "blocked", AIAgentDone = "done" }

--- AIAgentBlocked / AIAgentDone 路由入口（init.setup 订阅既有 User 事件，不新建
--- 轮询）：llm.auto_question 开 → auto_check 自动提取（对两个事件一视同仁，
--- 状态集过滤在其内）；关 → 仅 blocked 走原 notify hint（llm.hint 可关；
--- done 无 hint 语义）
function M.on_agent_state(data, event)
  local status = status_for_event[event] or (data and data.status)
  if llm_cfg().auto_question then
    M.auto_check(data, status)
    return
  end
  if status == "blocked" then
    M.notify_blocked(data)
  end
end

return M
