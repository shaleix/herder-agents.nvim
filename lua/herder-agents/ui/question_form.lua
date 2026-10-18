-- Agent 提问表单弹窗（pipeline: ui/question.lua 按契约调用；纯展示组件，
-- 不触碰 delivery/herdr/config，提交一律经 on_submit 交回管线）
--
-- 模块契约（签名不可偏离）：
--   M.open(spec, on_submit) → handle
--     spec = { mode="form", questions = { { label=string, question=string,
--              desc=string, options={string,...}, multiple=boolean,
--              suggested={1-based int,...} }, ... } }  -- 1..N 题（label = 该题在
--              终端原文里的原始标号元数据，可选；desc 说明行，可选）
--          | { mode="form", question=…, options=…, multiple=…, suggested=… } -- 旧扁平
--            单题 spec 仍被接受（等价 questions={一条}，过渡期老调用方不受影响）
--          | { mode="fallback", raw_text=string }
--     on_submit(text)：仅 <C-Enter> 提交时以最终文本回调一次；<Esc>/关窗不回调
--     直开表单不经 loading；返回 handle 仅为对称透出（set_stage 在非 loading 态
--     恒 no-op），既有调用方可继续忽略返回值
--   M.open_loading() → handle
--     立即弹出与表单同布局的 loading 骨架：标题「Agent 提问 · 提取中…」，内容
--     （spinner 帧动画 + 阶段感知文案）在固定高度内垂直居中，主行与附注行再
--     按 inner 宽逐行水平居中（合成一个视觉块整体居中）；输入行只读压暗；
--     loading 态仅 <Esc> 可取消。
--       handle.set_stage(stage, detail?)
--         stage ∈ "capture"|"extract"|"read_more"|"retry"，detail 如 "1/2"（追读
--         轮次）或上次失败原因（retry 附注，可选）；文案：捕获终端…/LLM 提取
--         中…/追读第 N/M 轮…/重试…
--       handle.morph_to(spec, on_submit) -- 参数与 M.open 完全同构；在 loading 或
--         旧表单上「原位变身」：复用同一 Layout 对象（仅重渲染行、重绑键位，
--         不卸载重挂、不调几何——宽度与高度全程恒等，dim 遮罩不闪）；句柄已
--         关闭则 no-op；变身后句柄委托当前表单的 close/closed 语义
--       handle.close() -- 幂等关闭（<Esc> 同源）；绝不触发任何回调
--       handle.closed / handle.is_closed() -- 管线判断迟到结果丢弃用
--     组件侧对迟到结果零回调：closed 后 set_stage/morph_to 均为 no-op
--   显示完成回调 config.options.question_form.on_show（可选函数，读取惯例同
--   height_ratio：config 缺失/字段缺失/非函数一律安全不触发）：
--     form/fallback 题面「显示完成」后触发一次——open 直开与 morph_to 变身两
--     条路径都算；每次新的显示触发一次（form→form 重问再触发）；loading 态不
--     触发；space 切换等重渲染不重复触发。触发点在初始光标/focus 应用之后
--     （用户调整最后落地）。on_show(ctx)：
--       ctx = { mode = "form"|"fallback",       -- fallback 时 questions 为空表
--               questions = {…},                -- 归一化后的题表
--               win = 题面 winid, buf = 题面 bufnr,
--               input_win = 输入行 winid, input_buf = 输入行 bufnr }
--     回调抛错仅 utils.warn 附错误、不破坏表单；随后 utils.emit
--     ("AIQuestionShown", ctx)（无论是否配置 on_show 事件都发，payload 同
--     ctx）。winid 在弹窗关闭后即失效；用户自建 namespace 的 extmark 不受本
--     组件重渲染影响（render 只清自有 ns）
--   M.compose(options, selected, custom) → string
--     纯函数：selected 为 1-based 索引数组、custom 为 string 或空；
--     输出 = 选中项原文（按选项顺序）逐行 + 自定义行原样，无任何前缀/模板
--   M.compose_questions(questions, answers, customs) → string
--     纯函数：answers[k]/customs[k] 为第 k 题的选中索引数组/自定义文本；
--     N=1 输出与 M.compose(q1.options, answers[1], customs[1]) 完全一致（原文
--     逐行 + 自定义行，无前缀——该题带 label 也不例外）；N>1 每题一块：块头 =
--     （该题 label 非空用原始标号，否则回退数组位置 `Qk`）.. ":"，其后选中项
--     原文逐行 + 非空自定义行，块间空行，无尾随空行
--
-- 固定几何（高度与宽度都会话期一次定死，loading/form/fallback/多题全程一致，
-- morph 只重渲染行、不调任何几何）：
--   弹窗总高 = 编辑器行数 × config.options.question_form.height_ratio（缺省回退
--   0.6，config 未就绪/字段缺失均可安全降级）；内容不足留白（loading 垂直居中），
--   超出靠 j/k/G 滚动。
--   弹窗宽度 = clamp_popup_width(编辑器列数 × width_ratio)（缺省回退 0.7）再
--   收敛到 [56, 88]（下限保持既有最小体量，上限沿用「一屏内聚焦」）；题头/
--   选项/原文/图例一律折行进固定宽度，宽度不再由内容反推——loading→form 变身
--   前后宽度逐像素恒等，零跳变。
--
-- 多问题分节视觉：每节以 `## <标号>` 行开头（ATX 标题：markdown ft 语法高亮自
-- 然生效，叠 HerderQFormQuestion 粗体 extmark；标号取该题 label，为空回退位置
-- 序号 `Qk`，N=1 同样有节头），节头与题干之间不空行（ATX 标题无 setext 风险），
-- 其后题干、空行、选项、✎ 自定义行、desc 说明行（desc 仅展示、Comment 压暗、
-- 绝不进入提交文本，为空时不产生任何额外行），节间一条 `---` 分割线（markdown
-- 主题断行，叠 extmark 保证可见；N=1 无分割线）。normalize_question 做防御性
-- 前缀剥离：label 非空且 question 以 label 开头（system_prompt 已要求编号进
-- label，这里兜底 LLM 漏剥）时剥掉这一处前导，label 为空不动——其余内容仍是
-- 唯一事实源、逐字渲染。题干与选项间空行、节间空行 + 分割线 + 空行防 setext；
-- 顶部标题体现「N 个问题（已答 a/N）」（计数不是前缀）。题面上框
-- buffer filetype=markdown + buftype=nofile：语法高亮生效，
-- 同时阻断 markview 等要求 buftype=="" 的 ft 插件 attach；续行缩进一律 ≤3
-- 空格、分割线前留空行，避免 4 空格缩进代码块 / setext 标题等 markdown 误判。
--
-- 已确认交互（勿改）：<Space>/x 切换选项（单选 radio 恒一项、重复 space 不反选，
-- 多选 checkbox 增删；只作用于光标所在题）；suggested 各题预选（单选取第一个、
-- 多选全取，越界忽略）、初始光标落第一题建议项；每题末尾「✎ 自定义答案…」伪
-- 选项行（后跟已填文本截断预览），其上 space/tab → 底部输入区按题重绑定（标题
-- 显示「自定义答案 · <label 或 第 k 题>」，N=1 纯「自定义答案」），tab 从输入区
-- 返回该题选项区，各题自定义互不干扰；<Tab> 选项区/输入行移动焦点；<C-Enter>
-- 任意焦点提交；<Esc>/q 取消；fallback = 只读 raw_text + 单一自定义输入行（不按
-- 题），提交仅自定义文本。
--
-- 空提交策略（严格未答拦截）：<C-Enter> 时任一题「0 选中且自定义空」→ 提示
-- 「未作答（<label 或 第 k 题>）：<题干预览>」（首个未答题；原始标号与 agent
-- 终端对得上，无标号回退位置序号；题干预览帮定位）、光标跳至该题首个选项、
-- 弹窗保留不提交（防误触把空答案发给 agent，与 Chat 空草稿拦截一致）。
--
-- 重复防护：沿用 current_close 惯例——open/open_loading/morph 后的弹窗同属一个
-- 会话，重复 open/open_loading 时旧弹窗（含 loading 骨架）让位关闭且不回调。
--
-- 模块 require 零副作用：nui 等依赖延迟到 open 内 require，headless 环境可直接
-- require 断言 M.compose/M.compose_questions，弹窗仅在 M.open/M.open_loading 创建。
local M = {}

local mapOpts = { noremap = true }

-- 已打开表单的关闭函数：重复 open 时先关旧弹窗（不回调），避免弹窗叠层
local current_close = nil

-- 本组件局部高亮（default=true 幂等定义，不改动 ui/common.lua）；
-- 选中/未选中沿用 Notes 勾选框的 String/LineNr 色系，保持插件内同一视觉语言
local function ensure_highlights()
  -- 合成「浮窗底 + 常规前景」：脱离 winhighlight 对 Normal 的窗口级重映射——
  -- 直接 link Normal 的组在该窗口内会被解析回浮窗灰（winhl 覆盖 Normal 本身），
  -- 故用 NormalFloat.bg + Normal.fg 现算（每次打开重算，跟随 colorscheme）；
  -- 取不到色（极端 headless/无色主题）则回落 NormalFloat 保底
  local ok_f, f = pcall(vim.api.nvim_get_hl, 0, { name = "NormalFloat", link = false })
  local ok_n, n = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  local composed = (ok_f and type(f) == "table" and f.bg) and { bg = f.bg } or {}
  if ok_n and type(n) == "table" and n.fg then
    composed.fg = n.fg
  end
  if next(composed) ~= nil then
    vim.api.nvim_set_hl(0, "HerderQFormNormal", composed)
  else
    vim.api.nvim_set_hl(0, "HerderQFormNormal", { link = "NormalFloat", default = true })
  end
  local defs = {
    HerderQFormQuestion = { link = "Title" }, -- 节头 ## 行 / ✎ 字形 / fallback 原文：主题标题色（多主题 bold+彩色）
    HerderQFormText = { link = "HerderQFormNormal" }, -- 正文（题干/选项文字）：常规前景 + 浮窗底（合成组，见上）
    HerderQFormOn = { link = "String" }, -- 选中字形 / ✎ 预览 / spinner 帧
    HerderQFormOff = { link = "LineNr" }, -- 未选中字形 / 「自定义答案…」标签
    HerderQFormDivider = { link = "Comment" }, -- 节间 `---` 分割线
  }
  for name, def in pairs(defs) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
  end
end

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

-- 逐 utf8 字符迭代
local function utf8_chars(s)
  return s:gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- 取显示宽度不超过 maxw 的最长前缀（至少返回 1 个字符，避免死循环）
local function take_dw(s, maxw)
  local out, w = "", 0
  for c in utf8_chars(s) do
    local cw = dw(c)
    if w + cw > maxw and w > 0 then
      break
    end
    out, w = out .. c, w + cw
  end
  return out
end

-- 按显示宽度折行：优先在空格处断行，超长词按字符硬折（CJK 天然逐字可断）
local function wrap_dw(text, maxw)
  maxw = math.max(1, math.floor(maxw))
  local out, cur, curw = {}, "", 0
  for word in tostring(text):gmatch("%S+") do
    local ww = dw(word)
    if curw > 0 and curw + 1 + ww <= maxw then
      cur, curw = cur .. " " .. word, curw + 1 + ww
    else
      if curw > 0 then
        out[#out + 1] = cur
        cur, curw = "", 0
      end
      while dw(word) > maxw do
        local head = take_dw(word, maxw)
        out[#out + 1] = head
        word = word:sub(#head + 1)
      end
      cur, curw = word, dw(word)
    end
  end
  out[#out + 1] = cur
  return out
end

-- 组装提交文本（单题语义，保留供 fallback/内部复用）：选中项（按选项顺序稳定
-- 输出，与 selected 传入顺序无关）逐行 + 自定义行原样（空串视为无自定义行）。
-- 纯函数：仅字符串拼接，无任何 vim/nui 调用
function M.compose(options, selected, custom)
  local picked = {}
  for _, i in ipairs(selected or {}) do
    picked[i] = true
  end
  local out = {}
  for i, opt in ipairs(options or {}) do
    if picked[i] then
      out[#out + 1] = type(opt) == "string" and opt or tostring(opt)
    end
  end
  if type(custom) == "string" and custom ~= "" then
    out[#out + 1] = custom
  end
  return table.concat(out, "\n")
end

-- 组装多题提交文本（纯函数）：
--   N=1 与 M.compose(q1.options, answers[1], customs[1]) 完全一致（无前缀，
--   带 label 也不例外）；N>1 每题一块：块头 =（label 非空用原始标号，否则回退
--   数组位置 "Qk"）.. ":" + 选中项原文逐行 + 非空自定义行，块间空行，无尾随空行
function M.compose_questions(questions, answers, customs)
  local qs = {}
  for _, q in ipairs(questions or {}) do
    qs[#qs + 1] = q
  end
  if #qs <= 1 then
    local q = qs[1] or {}
    local picked = (#qs == 1 and answers and answers[1]) or {}
    local custom = (#qs == 1 and customs and customs[1]) or nil
    return M.compose(q.options, picked, custom)
  end
  local blocks = {}
  for k, q in ipairs(qs) do
    local body = M.compose(q.options, answers and answers[k] or {}, customs and customs[k] or nil)
    local head = (type(q.label) == "string" and q.label ~= "") and q.label or ("Q" .. k)
    blocks[#blocks + 1] = body == "" and (head .. ":") or (head .. ":\n" .. body)
  end
  return table.concat(blocks, "\n\n")
end

-- 建议标记（渲染在选项文本末尾，放不下则独占一行；Comment 灰）
local MARKER = "· 建议"

-- ✎ 自定义答案伪选项行
local PEN_GLYPH = "✎"
local PEN_LABEL = "自定义答案…"

-- ── loading 态常量（模块级纯数据，无副作用）──
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 120 -- 帧间隔；10 帧 ≈ 1.2s 一轮
local LOADING_MIN_ROWS = 3 -- loading 内容行数下限：空行 / spinner+文案 / 附注
local MIN_W = 56 -- 弹窗宽度下限：保持既有最小体量（原 loading 骨架基宽）
local MAX_W = 88 -- 弹窗宽度上限：沿用「一屏内聚焦」体量（原内容自适应上限）
local STAGE_LABELS = {
  capture = "捕获终端…",
  extract = "LLM 提取中…",
}
local CHROME_ROWS = 6 -- 弹窗总高 → 上框内容行的换算：边框2 + 底衬1 + 输入行外框3

local DEFAULT_HEIGHT_RATIO = 0.6
local DEFAULT_WIDTH_RATIO = 0.7

-- 固定高度比例：config.options.question_form.height_ratio（另一 lane 添加）；
-- config 缺失/字段缺失/非法值一律安全回退 0.6
local function read_height_ratio()
  local ok, config = pcall(require, "herder-agents.config")
  if ok and type(config) == "table" and type(config.options) == "table"
    and type(config.options.question_form) == "table"
    and type(config.options.question_form.height_ratio) == "number"
    and config.options.question_form.height_ratio > 0 then
    return config.options.question_form.height_ratio
  end
  return DEFAULT_HEIGHT_RATIO
end

-- 固定宽度比例：config.options.question_form.width_ratio；与 read_height_ratio
-- 同构的完整缺省回退链——config 缺失/字段缺失/非 number/≤0 一律安全回退 0.7
local function read_width_ratio()
  local ok, config = pcall(require, "herder-agents.config")
  if ok and type(config) == "table" and type(config.options) == "table"
    and type(config.options.question_form) == "table"
    and type(config.options.question_form.width_ratio) == "number"
    and config.options.question_form.width_ratio > 0 then
    return config.options.question_form.width_ratio
  end
  return DEFAULT_WIDTH_RATIO
end

-- 显示完成回调：config.options.question_form.on_show（form/fallback 题面显示
-- 完成后触发一次，ctx 形状见 start_ui 内 fire_shown 注释）；与 read_height_ratio
-- 同构的惰性 require / 完整缺省回退链——config 缺失/字段缺失/非函数一律安全
-- 回退 nil（不触发、不影响表单）
local function read_on_show()
  local ok, config = pcall(require, "herder-agents.config")
  if ok and type(config) == "table" and type(config.options) == "table"
    and type(config.options.question_form) == "table"
    and type(config.options.question_form.on_show) == "function" then
    return config.options.question_form.on_show
  end
  return nil
end

-- 单题 spec 归一化：question/options 字符串化、suggested 越界过滤（保持传入顺序，
-- radio 初始选中取第一个有效建议）；question 做防御性前缀剥离——label 非空且
-- question 以 label 开头、后跟分隔符 [-–—:：.、)] 与空白时剥掉这一处前导
-- （system_prompt 已要求编号进 label，这里兜底 LLM 漏剥；剥后为空则不剥；
-- label 为空不动），其余逐字不改写；options 一律逐字不动；
-- desc 仅 tostring 归一（缺省 ""），不做任何清洗，渲染层原样展示；
-- label 仅 tostring 归一（缺省 ""）——原始标号元数据，驱动节头 `## <label>`、
-- 提交块头 / 未答拦截提示 / 输入行标题
local function normalize_question(q)
  q = type(q) == "table" and q or {}
  local label = tostring(q.label or "")
  local question = tostring(q.question or "")
  -- 防御性剥离：question 以 label 开头、后跟分隔符/空白（如 "Q2 - foo"）时剥掉
  -- 这一处前导（取最长分隔/空白 run 一起剥，避免回溯残留下一个分隔符）；
  -- 剥后为空（题干就是标号本身）则不剥；label 为空不动
  if label ~= "" and question:sub(1, #label) == label then
    local rest = question:sub(#label + 1)
    local run = rest:match("^[%s%-–—:：.、)]+")
    local body = run and rest:sub(#run + 1) or nil
    if body and body ~= "" then
      question = body
    end
  end
  local item = {
    question = question,
    desc = tostring(q.desc or ""),
    label = label,
    options = {},
    multiple = q.multiple == true,
    suggested = {},
    suggested_set = {},
  }
  if type(q.options) == "table" then
    for _, o in ipairs(q.options) do
      item.options[#item.options + 1] = tostring(o or "")
    end
  end
  if type(q.suggested) == "table" then
    for _, i in ipairs(q.suggested) do
      if type(i) == "number" and item.options[i] then
        item.suggested[#item.suggested + 1] = i
        item.suggested_set[i] = true
      end
    end
  end
  return item
end

-- 弹窗会话：一组常驻 Layout/Popup（top 题面区 + input 自定义答案行）贯穿
-- loading → form/fallback（或 form → form）全生命周期。所有变身都在同一批
-- 窗口/缓冲上原位完成（不卸载重挂）；几何（宽度与高度）在会话创建时一次
-- 定死（loading/form/fallback/多题全程一致，morph 只重渲染，不调几何）。
-- initial = { loading = true } | { spec = spec, on_submit = fn }
local function start_ui(initial)
  if current_close then
    current_close() -- 旧弹窗（含 loading 骨架/表单）直接关闭（不回调），让位新问题
  end

  -- 依赖全部在会话内加载：保证模块 require 零副作用（headless 无 nui 也可断言 compose）
  local common = require("herder-agents.ui.common")
  local utils = require("herder-agents.utils")
  local Popup = require("nui.popup")
  local NuiText = require("nui.text")
  local Layout = require("nui.layout")

  ensure_highlights()
  local ns = vim.api.nvim_create_namespace("herder_agents_question_form")

  local born_loading = initial.loading == true

  -- ── 固定高度：编辑器行数 × ratio，收敛到 [loading 最小体量, 屏高-1] ──
  local total_h = math.floor(vim.o.lines * read_height_ratio())
  total_h = math.max(LOADING_MIN_ROWS + CHROME_ROWS, math.min(total_h, vim.o.lines - 1))
  local fixed_rows = total_h - CHROME_ROWS -- 上框内容行数（不足留白，超出滚动）

  -- ── 固定宽度：编辑器列数 × ratio，先 clamp 到屏宽 90% 再收敛 [MIN_W, MAX_W]。
  -- 与高度同一哲学：会话期一次定死，loading/form/fallback/多题全程同宽（morph
  -- 不再触碰几何）；宽度不随内容自适应——内容一律折行进该宽度，零宽度跳变 ──
  local width = common.clamp_popup_width(math.floor(vim.o.columns * read_width_ratio()))
  width = math.max(MIN_W, math.min(MAX_W, width))
  -- 折行预算按实测留足：布局宽 W → 窗口内容区(含左右 padding)为 W-4，再扣
  -- padding 2 列 → 文本安全宽度 = W-6（宁余勿溢出，避免最宽行右端被裁）
  local inner = math.max(8, width - 6)

  -- ── 会话状态（morph 时由 apply_spec 整体重算；几何 width/inner/fixed_rows
  -- 会话期恒定，不在重算范围）──
  local mode = "loading" -- "loading" | "form" | "fallback"
  local is_form = true
  local questions = {} -- 归一化后的题目数组（1..nq）
  local nq = 0
  local raw_text = ""
  local sel = {} -- sel[k] = { [选项索引] = true }
  local customs = {} -- customs[k] = 第 k 题自定义文本（trim 后）
  local on_submit_cb = function() end
  local closed, submitted = false, false
  local focus = nil -- "options" | "input"（loading 态不适用）
  local row_meta = {} -- 物理行 → { kind, q, opt }（kind: header/blank/divider/option/pen/raw）
  local q_first_row = {} -- 题号 → 节首个内容行（跳过分割线）
  local q_opt_first_row = {} -- 题号 → { 选项索引 → 首个物理行 }
  local q_pen_row = {} -- 题号 → ✎ 行
  local input_q = 1 -- 输入行当前绑定的题号（fallback 不适用）
  local leave_row = {} -- 题号 → 离开选项区时光标行（tab 返回时回到原位附近）

  -- ── loading 状态 ──
  local stage, stage_detail = "capture", nil
  local frame = 1
  local spinner_timer = nil

  local function legend_for(form)
    return form and " space 选择 · tab 焦点 · ctrl+enter 提交 · esc 取消 "
      or " tab 焦点 · ctrl+enter 提交 · esc 取消 "
  end

  -- 第 k 题是否已作答（有选中或有自定义）
  local function question_answered(k)
    if next(sel[k] or {}) ~= nil then
      return true
    end
    return (customs[k] or "") ~= ""
  end

  -- 未答拦截提示的题干预览：题干前 ~30 显示宽字符，超出截断加 …（拦截点名用
  -- 原始标号 label、无标号回退位置序号；题干预览帮定位）
  local function stem_preview(text)
    local s = tostring(text or "")
    if dw(s) > 30 then
      return take_dw(s, 30) .. "…"
    end
    return s
  end

  local function title_text()
    if mode == "loading" then
      return " Agent 提问 · 提取中… "
    end
    if not is_form then
      return " Agent 提问 · 原文 "
    end
    if nq > 1 then
      local done = 0
      for k = 1, nq do
        if question_answered(k) then
          done = done + 1
        end
      end
      return string.format(" Agent 提问 · %d 个问题（已答 %d/%d） ", nq, done, nq)
    end
    -- 单题沿用历史标题（单选/多选 + 已选计数）
    if questions[1] and questions[1].multiple then
      local n = 0
      for _ in pairs(sel[1]) do
        n = n + 1
      end
      return string.format(" Agent 提问 · 多选（已选 %d） ", n)
    end
    return " Agent 提问 · 单选 "
  end

  -- 输入行标题：多题显示当前绑定题（原始标号 label 优先，无则位置「第 k 题」），
  -- 单题/fallback 纯「自定义答案」
  local function input_title_text()
    if is_form and nq > 1 then
      local q = questions[input_q]
      local name = q and q.label ~= "" and q.label or ("第 " .. input_q .. " 题")
      return string.format(" 自定义答案 · %s ", name)
    end
    return " 自定义答案 "
  end

  local function legend_text()
    if mode == "loading" then
      return " esc 取消 "
    end
    return legend_for(is_form)
  end

  -- 行模型：每行 { text, marks = { {起始字节, 结束字节, hl组} }, kind, q, opt }。
  -- 题面文本（节头/题干/fallback 原文）不再整行压 extmark——filetype=markdown 的
  -- 语法高亮直接生效（ATX 节头/代码块/加粗等与手工折行共存）；extmark 只用于
  -- 结构性字形（节头粗体/选项框/✎/分割线）。
  local function build_rows()
    local rows = {}
    local function add(text, marks, kind, q, opt)
      rows[#rows + 1] = { text = text, marks = marks or {}, kind = kind, q = q, opt = opt }
    end

    if is_form then
      for k, q in ipairs(questions) do
        if k > 1 then
          -- 空行对称包住分割线：上下各一空行（上方防「文本行 + 紧随 ---」被
          -- markdown 误判 setext 标题下划线；下方让 --- 与下一节内容呼吸）
          add("", {}, "blank", k, nil)
          add(string.rep("-", inner), { { 0, inner, "HerderQFormDivider" } }, "divider", k, nil)
          add("", {}, "blank", k, nil)
        end
        -- 节头与题干同行：`## <标号> <题干首段>`（label 非空用原始标号，否则回退
        -- 位置序号 Qk；N=1 同样有）。ATX 标题整行生效（markdown ft 语法高亮），
        -- 「## 标号」前缀压 HerderQFormQuestion 粗体 extmark；题干首段折行预算
        -- 扣除节头宽 + 连接空格，续行平齐不缩进；不参与 space 选择；题干为空
        -- 则整行仅节头
        local head_label = q.label ~= "" and q.label or ("Q" .. k)
        local head = "## " .. head_label
        if q.question == "" then
          add(head, { { 0, #head, "HerderQFormQuestion", 50 } }, "qhead", k, nil)
        else
          local budget = math.max(8, inner - dw(head) - 1)
          local segs = wrap_dw(q.question, budget)
          -- 正文不加整行 extmark：窗口 Normal（合成组）已打底亮色，markdown
          -- 语法/TS 高亮（**、`code`、标题…）直接可见；节头前缀仅作低优先级
          --（50 < TS 常规 100）兜底——有语法高亮时让位，无 TS/syntax 环境保底
          add(head .. " " .. segs[1], { { 0, #head, "HerderQFormQuestion", 50 } }, "qhead", k, nil)
          for si = 2, #segs do
            add(segs[si], {}, "header", k, nil)
          end
        end
        add("", {}, "blank", k, nil) -- 题干与选项间空一行（防 setext、版式呼吸）
        local opt_w = math.max(4, inner - 2) -- 扣除前缀 2 列（✓ / 空格占位）
        for i, o in ipairs(q.options) do
          local osegs = wrap_dw(o, opt_w)
          -- 建议标记贴文本末尾，放不下则独占一行（缩进对齐文本列）；字节区间供高亮
          local mrange = nil
          if q.suggested_set[i] then
            local mtext = "  " .. MARKER
            local last = osegs[#osegs]
            if dw(last) + dw(mtext) <= opt_w then
              osegs[#osegs] = last .. mtext
              mrange = { #last, #osegs[#osegs] }
            else
              osegs[#osegs + 1] = MARKER
              mrange = { 0, #MARKER }
            end
          end
          for si, seg in ipairs(osegs) do
            local text, marks, off
            if si == 1 then
              local on = sel[k][i] == true
              -- 无框字形：选中 = 绿色 ✓ 前缀（✓ 3 字节），未选中 = 等宽空格占位
              --（文字起点恒对齐、切换不横跳）；单选/多选同形，语义由标题栏表达；
              -- 文字留给 markdown 语法高亮，未命中语法的落窗口 Normal（合成组）
              local glyph = on and "✓ " or "  "
              text = glyph .. seg
              off = #glyph
              marks = on and { { 0, off - 1, "HerderQFormOn" } } or {}
            else
              text = "  " .. seg -- 2 空格续行：与首段文字列对齐
              off = 2
              marks = {}
            end
            if mrange and si == #osegs then
              marks[#marks + 1] = { off + mrange[1], off + mrange[2], "Comment" }
            end
            add(text, marks, "option", k, i)
          end
        end
        -- ✎ 自定义答案伪选项行（预览截断到内宽；已填时预览亮 String 色）
        local prefix = PEN_GLYPH .. " "
        local base = prefix .. PEN_LABEL
        local ptext = base
        local pmarks = {
          { 0, #PEN_GLYPH, "HerderQFormQuestion" },
          { #prefix, #base, "HerderQFormOff" },
        }
        local preview = customs[k] or ""
        if preview ~= "" then
          local budget = inner - dw(base) - 2
          if budget >= 4 then
            local shown = preview
            if dw(shown) > budget then
              shown = take_dw(shown, budget - 1) .. "…"
            end
            ptext = base .. "  " .. shown
            pmarks[#pmarks + 1] = { #base + 2, #ptext, "HerderQFormOn" }
          end
        end
        add(ptext, pmarks, "pen", k, nil)
        -- desc 说明行（仅展示、不进提交文本）：渲染在 ✎ 行之后（节尾，建议/
        -- 选项/自定义区之后收束说明）；Comment 压暗（与「· 建议」标记/图例同
        -- 语系），折满 inner、续行平齐不缩进（与题干续行同策略）；不参与 space
        -- 选择（row_opt 为 nil）；desc 为空 → 不产生任何额外行
        if q.desc ~= "" then
          for _, seg in ipairs(wrap_dw(q.desc, inner)) do
            add(seg, { { 0, #seg, "Comment" } }, "desc", k, nil)
          end
        end
      end
    else
      for _, line in ipairs(vim.split(raw_text:gsub("\r", ""), "\n", { plain = true })) do
        for _, seg in ipairs(wrap_dw(line, inner)) do
          add(seg, {}, "raw", nil, nil)
        end
      end
    end
    if #rows == 0 then
      add("", {}, "raw", nil, nil)
    end
    return rows
  end

  -- spec 解析 + 会话状态重算（open 直开与 morph 共用；必须在弹窗渲染前完成）。
  -- 几何不在此重算：宽度/高度会话期一次定死（见上方固定几何块），内容一律
  -- 折行进固定宽度——宽度不再由内容反推。
  local function apply_spec(spec, on_submit)
    spec = spec or {}
    on_submit_cb = on_submit or function() end
    submitted = false

    is_form = spec.mode ~= "fallback"
    questions = {}
    raw_text = ""
    sel, customs, input_q, leave_row = {}, {}, 1, {}
    if is_form then
      if type(spec.questions) == "table" and #spec.questions > 0 then
        for _, q in ipairs(spec.questions) do
          questions[#questions + 1] = normalize_question(q)
        end
      elseif type(spec.options) == "table" or type(spec.question) == "string" then
        -- 旧扁平单题 spec：等价 questions={一条}（N=1 输出与历史完全一致）
        questions[1] = normalize_question(spec)
      end
    else
      raw_text = tostring(spec.raw_text or "")
    end
    nq = #questions

    -- 选中初值：单选取第一个有效 suggested（无则初始无选中），多选取全部 suggested
    for k, q in ipairs(questions) do
      local s = {}
      if q.multiple then
        for i in pairs(q.suggested_set) do
          s[i] = true
        end
      else
        for _, i in ipairs(q.suggested) do
          s[i] = true
          break
        end
      end
      sel[k] = s
      customs[k] = ""
    end
    focus = is_form and "options" or "input"
  end

  if not born_loading then
    apply_spec(initial.spec, initial.on_submit)
    mode = is_form and "form" or "fallback"
  end

  -- ── 常驻骨架：与表单同布局（top + input），loading 与 morph 共用；几何恒定 ──
  local top_enter = born_loading or is_form -- form：初始聚焦选项区；fallback：聚焦输入行；loading：聚焦 loading 区

  -- 与 Chat/Notes 同款视觉：空格边框 + 悬浮标题；Normal 映射为合成组
  -- HerderQFormNormal（NormalFloat 底 + Normal 前景，正文不落浮窗灰）。
  -- filetype=markdown 让题面拿到真语法高亮；buftype=nofile 阻断 markview 等
  -- 要求 buftype=="" 的插件 attach；conceallevel=2（窗口局部）隐去 markdown
  -- 记号（## / ** / `` 等），题面呈现渲染后效果（用户指定；字形/分割线是
  -- 纯文本不受 conceal 影响）
  local top_popup = Popup({
    position = "50%",
    size = { width = width, height = fixed_rows },
    enter = top_enter,
    border = {
      padding = { left = 1, right = 1, top = 0, bottom = 1 },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(title_text(), "FloatTitle"),
        top_align = "center",
      },
    },
    buf_options = {
      filetype = "markdown",
      buftype = "nofile",
      modifiable = false,
    },
    win_options = {
      winhighlight = "Normal:HerderQFormNormal,FloatBorder:AiderInputFloatBorder",
      cursorline = true, -- 焦点行高亮：选项区有焦点时可见，聚焦输入行时自然熄灭（loading 态显式关闭）
      wrap = false, -- 折行已在渲染时完成，禁止窗口二次折行错位
      conceallevel = 2, -- 窗口局部：隐去 markdown 记号（##/**/``），渲染后观感
      fillchars = "eob: ", -- 固定高度下短内容以纯留白收尾，不显示 ~ 填充
    },
  })

  local input_popup = Popup({
    position = "50%",
    size = { width = width, height = 1 },
    enter = (not born_loading) and not is_form,
    border = {
      padding = { left = 1, right = 1 },
      style = { " ", " ", " ", " ", " ", " ", " ", " " },
      text = {
        top = NuiText(input_title_text(), "LineNr"),
        top_align = "left",
        bottom = NuiText(legend_text(), "LineNr"),
        bottom_align = "right",
      },
    },
    buf_options = { filetype = "herder-question-input" },
    win_options = {
      winhighlight = "Normal:HerderQFormNormal,FloatBorder:AiderInputFloatBorder",
      wrap = false, -- 输入行横向滚动不折行（表单输入框惯例）
    },
  })

  -- 上：题头+选项（grow 自适应，高度恒为 fixed_rows）；下：自定义答案输入行
  --（外框高 3 = 内容 1 + 边框 2）。布局宽 width、总高 fixed_rows + 6 全程不变。
  local layout = Layout(
    {
      position = "50%",
      relative = "editor",
      size = { width = width, height = total_h },
    },
    Layout.Box({
      Layout.Box(top_popup, { grow = 1 }),
      Layout.Box(input_popup, { size = { height = 3 } }),
    }, { dir = "col" })
  )

  local original_winid = vim.api.nvim_get_current_win()
  local buf = top_popup.bufnr

  -- ── spinner（uv timer 驱动；close/morph 必须停止，杜绝句柄泄漏）──
  local uv = vim.uv or vim.loop
  local render_loading -- 前向声明：spinner 回调先引用、定义见下（避免解析成全局）

  local function stop_spinner()
    local t = spinner_timer
    if not t then
      return
    end
    spinner_timer = nil
    if not t:is_closing() then
      pcall(function()
        t:stop()
      end)
      pcall(function()
        t:close()
      end)
    end
  end

  local function start_spinner()
    stop_spinner()
    local t = uv.new_timer()
    if not t then
      return
    end
    spinner_timer = t
    t:start(
      SPINNER_MS,
      SPINNER_MS,
      vim.schedule_wrap(function()
        if closed or mode ~= "loading" then
          stop_spinner()
          return
        end
        frame = frame % #SPINNER_FRAMES + 1
        render_loading()
      end)
    )
  end

  local function close()
    if closed then
      return
    end
    closed = true
    stop_spinner()
    if current_close == close then
      current_close = nil
    end
    layout:unmount()
    -- 提交/取消可能发生在插入模式：卸载后显式退回 normal，避免焦点回源窗口时误改代码
    if vim.api.nvim_get_mode().mode:match("^[iR]") then
      vim.cmd("stopinsert")
    end
    if original_winid and vim.api.nvim_win_is_valid(original_winid) then
      pcall(vim.api.nvim_set_current_win, original_winid)
    end
  end
  current_close = close

  -- 焦点可视化：被聚焦区域的标题亮（FloatTitle），另一侧压暗（LineNr）；
  -- loading：题头恒亮、输入行压暗（未就绪）；底沿图例随形态换装（morph 后更新）
  local function sync_focus_titles()
    local top_hl, input_hl
    if mode == "loading" then
      top_hl, input_hl = "FloatTitle", "LineNr"
    elseif is_form then
      top_hl = focus == "options" and "FloatTitle" or "LineNr"
      input_hl = focus == "input" and "FloatTitle" or "LineNr"
    else
      top_hl = "FloatTitle" -- fallback 题面是信息主体，恒亮
      input_hl = focus == "input" and "FloatTitle" or "LineNr"
    end
    pcall(top_popup.border.set_text, top_popup.border, "top", NuiText(title_text(), top_hl), "center")
    pcall(input_popup.border.set_text, input_popup.border, "top", NuiText(input_title_text(), input_hl), "left")
    pcall(input_popup.border.set_text, input_popup.border, "bottom", NuiText(legend_text(), "LineNr"), "right")
  end

  -- 全量重渲染（每次切换后重建；固定高度下行数可少于/多于可视区，光标位置尽量保持）
  local function render()
    if closed or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local rows = build_rows()
    local lines = {}
    row_meta, q_first_row, q_opt_first_row, q_pen_row = {}, {}, {}, {}
    for i, r in ipairs(rows) do
      lines[i] = r.text
      row_meta[i] = { kind = r.kind, q = r.q, opt = r.opt }
      if r.q and r.kind ~= "divider" and not q_first_row[r.q] then
        q_first_row[r.q] = i
      end
      if r.kind == "option" and r.q then
        q_opt_first_row[r.q] = q_opt_first_row[r.q] or {}
        if not q_opt_first_row[r.q][r.opt] then
          q_opt_first_row[r.q][r.opt] = i
        end
      elseif r.kind == "pen" and r.q then
        q_pen_row[r.q] = i
      end
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, r in ipairs(rows) do
      for _, m in ipairs(r.marks) do
        if m[2] > m[1] then
          -- m = { 起始字节, 结束字节, hl组, 优先级? }——优先级缺省为 nvim 默认；
          -- 低优先级（如 50）让 markdown 语法/TS 高亮在其上生效，仅作无语法时的兜底
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, m[1], {
            end_col = m[2],
            hl_group = m[3],
            priority = m[4],
          })
        end
      end
    end
    -- 高度固定：行数收缩时收敛光标防越界（行数不变时不动光标）
    if top_popup.winid and vim.api.nvim_win_is_valid(top_popup.winid) then
      local row = vim.api.nvim_win_get_cursor(top_popup.winid)[1]
      if row > #lines then
        pcall(vim.api.nvim_win_set_cursor, top_popup.winid, { math.max(1, #lines), 0 })
      end
    end
    sync_focus_titles()
  end

  -- loading 区渲染（固定高度内垂直居中 + 按 inner 宽水平居中）：空行 /
  -- spinner+阶段文案 / 附注（截断到一行），上下以留白补齐 fixed_rows；主行与
  -- 附注行各自逐行计算左填充（空行不填充）——spinner 行与文案行合成一个视觉
  -- 块整体居中，帧动画/阶段切换重渲染都重算填充，位置与居中保持稳定；
  -- extmark 高亮区间随填充平移到新字节区间（lead 为 ASCII 空格，列数=字节数）
  render_loading = function()
    if closed or mode ~= "loading" then
      return
    end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local label
    if stage == "read_more" then
      label = (type(stage_detail) == "string" and stage_detail ~= "") and ("追读第 " .. stage_detail .. " 轮…")
        or "追读终端…"
    elseif stage == "retry" then
      label = "重试…"
    else
      label = STAGE_LABELS[stage] or "处理中…"
    end
    local sub = (stage ~= "read_more" and type(stage_detail) == "string" and stage_detail ~= "") and stage_detail or ""
    local linner = inner -- loading 附注截断预算 = 表单折行同一内宽（宽度恒定）
    if sub ~= "" and dw(sub) > linner then
      sub = take_dw(sub, linner - 1):gsub("%s+$", "") .. "…"
    end
    local glyph = SPINNER_FRAMES[frame]
    local main = glyph .. "  " .. label
    -- 水平居中：lead = floor((inner − 行显示宽) / 2)（超宽退化为不填充，防御
    -- 理论上的极窄 inner；附注已截断、文案远短于 inner，正常路径不触发）
    local function center_pad(text)
      if text == "" then
        return text, 0
      end
      local lead = math.max(0, math.floor((inner - dw(text)) / 2))
      return string.rep(" ", lead) .. text, lead
    end
    local main_line, main_lead = center_pad(main)
    local sub_line, sub_lead = center_pad(sub)
    local pad = math.floor((fixed_rows - 3) / 2)
    local lines = {}
    for i = 1, pad do
      lines[i] = ""
    end
    lines[pad + 1] = ""
    lines[pad + 2] = main_line
    lines[pad + 3] = sub_line
    for i = pad + 4, fixed_rows do
      lines[i] = ""
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, pad + 1, main_lead, { end_col = main_lead + #glyph, hl_group = "HerderQFormOn" })
    vim.api.nvim_buf_set_extmark(buf, ns, pad + 1, main_lead + #glyph + 2, { end_col = main_lead + #main, hl_group = "HerderQFormQuestion" })
    if sub ~= "" then
      vim.api.nvim_buf_set_extmark(buf, ns, pad + 2, sub_lead, { end_col = sub_lead + #sub, hl_group = "Comment" })
    end
    sync_focus_titles()
  end

  local function meta_at_cursor()
    if not top_popup.winid or not vim.api.nvim_win_is_valid(top_popup.winid) then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(top_popup.winid)[1]
    return row_meta[row], row
  end

  -- 输入行草稿归位当前绑定题（trim；空串=未填）
  local function flush_input()
    if not is_form then
      return
    end
    if not input_popup.bufnr or not vim.api.nvim_buf_is_valid(input_popup.bufnr) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, -1, false)
    customs[input_q] = vim.trim(table.concat(lines, "\n"))
  end

  -- 输入区按题重绑定：旧题草稿归位、新题草稿回填（同题重复绑定不动缓冲，
  -- 输入中的草稿不丢）
  local function bind_input(q)
    if not is_form or type(q) ~= "number" or not questions[q] then
      return
    end
    if q == input_q then
      return
    end
    flush_input()
    input_q = q
    if input_popup.bufnr and vim.api.nvim_buf_is_valid(input_popup.bufnr) then
      local text = customs[input_q] or ""
      local lines = text == "" and { "" } or vim.split(text, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(input_popup.bufnr, 0, -1, false, lines)
    end
  end

  -- Tab 目标：聚焦输入行并进入插入（光标行尾，GA 语义：立即可输入/续写）
  local function focus_input()
    if closed or not input_popup.winid or not vim.api.nvim_win_is_valid(input_popup.winid) then
      return
    end
    focus = "input"
    vim.api.nvim_set_current_win(input_popup.winid)
    sync_focus_titles()
    if not vim.api.nvim_get_mode().mode:match("^i") then
      vim.api.nvim_feedkeys("GA", "m", false)
    end
  end

  -- 聚焦输入行并绑定到第 q 题（✎ 行 space/tab 与选项区 Tab 共用）；
  -- q 为空时绑定光标所在节；离开选项区时记录返回行
  local function focus_input_for(q)
    if not is_form then
      focus_input()
      return
    end
    local m, row = meta_at_cursor()
    if focus == "options" and m and m.q and row then
      leave_row[m.q] = row
    end
    bind_input(q or (m and m.q) or input_q)
    focus_input()
  end

  -- Tab 目标（输入行侧）：聚焦选项区。form：回到输入行当前绑定题，优先落回
  -- 离开时的行（失效则该题首选项/✎ 行），并刷新 ✎ 预览与标题已答计数
  local function focus_options_for_input()
    if closed or not top_popup.winid or not vim.api.nvim_win_is_valid(top_popup.winid) then
      return
    end
    local row = 1
    if is_form then
      flush_input()
      local k = input_q
      row = leave_row[k]
      if not row or not row_meta[row] or row_meta[row].q ~= k then
        row = (q_opt_first_row[k] and q_opt_first_row[k][1]) or q_pen_row[k] or q_first_row[k] or 1
      end
    end
    focus = "options"
    vim.api.nvim_set_current_win(top_popup.winid)
    render() -- ✎ 预览/已答计数随草稿归位刷新
    pcall(vim.api.nvim_win_set_cursor, top_popup.winid, { row, 0 })
    sync_focus_titles()
    if vim.api.nvim_get_mode().mode:match("^i") then
      vim.api.nvim_input("<C-[>")
    end
  end

  -- 显示完成回调收口：form/fallback 题面「显示完成」后触发一次——open 直开与
  -- morph_to 变身两条路径都在初始光标/focus 应用之后调用本函数（该点即显示
  -- 收口点：用户调整最后落地）；loading 态不触发；space 切换等重渲染不重复
  -- 触发（render 不经过这里）；每次新的显示触发一次，form→form 重问再触发。
  -- ctx 形状：
  --   mode = "form"|"fallback"      -- 形态（fallback 时 questions 为空表）
  --   questions = {…}               -- 归一化后的题表
  --   win / buf                     -- 题面窗口/缓冲
  --   input_win / input_buf         -- 自定义答案输入行窗口/缓冲
  -- 注意：winid 在弹窗关闭后即失效（buf 仍在但已被组件置不可改）；用户自建
  -- namespace 的 extmark 不受本组件重渲染影响（render 只清自有 ns）。on_show
  -- 抛错仅 utils.warn 附错误、不破坏表单；随后 utils.emit("AIQuestionShown",
  -- ctx)（无论是否配置 on_show 事件都发，payload 同 ctx）。
  local function fire_shown()
    local ctx = {
      mode = is_form and "form" or "fallback",
      questions = questions,
      win = top_popup.winid,
      buf = buf,
      input_win = input_popup.winid,
      input_buf = input_popup.bufnr,
    }
    local on_show = read_on_show()
    if type(on_show) == "function" then
      local ok, err = pcall(on_show, ctx)
      if not ok then
        utils.warn("question_form.on_show error: " .. tostring(err))
      end
    end
    utils.emit("AIQuestionShown", ctx)
  end

  -- <Space>/x：作用于光标所在题——选项行切换（radio 恒一项、重复不反选；
  -- checkbox 增删），✎ 行转进该题输入区，其余行 no-op
  local function toggle_at_cursor()
    if not is_form then
      return
    end
    local m, row = meta_at_cursor()
    if not m then
      return
    end
    if m.kind == "pen" then
      focus_input_for(m.q)
      return
    end
    if m.kind ~= "option" then
      return
    end
    local q = questions[m.q]
    if q.multiple then
      if sel[m.q][m.opt] then
        sel[m.q][m.opt] = nil
      else
        sel[m.q][m.opt] = true
      end
    else
      sel[m.q] = { [m.opt] = true } -- radio：始终恰一项；对已选项 space 不反选
    end
    render()
    pcall(vim.api.nvim_win_set_cursor, top_popup.winid, { row, 0 })
  end

  -- <C-Enter> 提交：任意焦点可用；严格未答拦截——第一个「0 选中且自定义空」的
  -- 题被点名（未作答（<label 或 第 k 题>）：<题干预览>）后弹窗保留，光标跳至
  -- 该题首个选项（选项区有焦点时）
  local function submit()
    if closed or submitted then
      return
    end
    flush_input() -- 输入行草稿归位当前绑定题
    local lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, -1, false)
    local custom = vim.trim(table.concat(lines, "\n"))
    if is_form then
      if nq == 0 and custom == "" then -- 空表单兜底：延续既有空提交拦截
        utils.warn("No option selected and custom answer is empty")
        return
      end
      for k = 1, nq do
        if not question_answered(k) then
          local name = questions[k].label ~= "" and questions[k].label or ("第 " .. k .. " 题")
          utils.warn(string.format("未作答（%s）：%s", name, stem_preview(questions[k].question)))
          if focus == "options" and top_popup.winid and vim.api.nvim_win_is_valid(top_popup.winid) then
            local row = (q_opt_first_row[k] and q_opt_first_row[k][1]) or q_pen_row[k] or q_first_row[k] or 1
            pcall(vim.api.nvim_set_current_win, top_popup.winid)
            pcall(vim.api.nvim_win_set_cursor, top_popup.winid, { row, 0 })
          end
          render() -- ✎ 预览/已答计数刷新
          return -- 弹窗保留，不提交
        end
      end
      local answers = {}
      for k = 1, nq do
        local picked = {}
        for i in pairs(sel[k]) do
          picked[#picked + 1] = i
        end
        table.sort(picked)
        answers[k] = picked
      end
      submitted = true
      close()
      on_submit_cb(M.compose_questions(questions, answers, customs)) -- 恰一次
    else
      if custom == "" then
        utils.warn("Custom answer is empty")
        return
      end
      submitted = true
      close()
      on_submit_cb(custom)
    end
  end

  -- 完整表单键位表（open 直开与 morph 共用；同 lhs 重绑覆盖 loading 绑定）
  local toggle_bound = false
  local function bind_form_maps()
    -- 选项区（normal）：Tab → 输入行（按光标所在题重绑定）；space/x 切换（x 与
    -- Notes 视图一致；✎ 行上转进该题输入区）
    top_popup:map("n", "<Tab>", function()
      if is_form then
        local m = meta_at_cursor()
        focus_input_for(m and m.q)
      else
        focus_input_for(nil)
      end
    end, mapOpts)
    top_popup:map("n", "<C-Enter>", submit, mapOpts)
    top_popup:map("i", "<C-Enter>", submit, mapOpts) -- 防御：选项区意外进入插入时仍可提交
    top_popup:map("n", "<Esc>", close, mapOpts)
    top_popup:map("n", "q", close, mapOpts)
    top_popup:map("n", "<C-q>", close, mapOpts)
    if is_form then
      top_popup:map("n", "<Space>", toggle_at_cursor, mapOpts)
      top_popup:map("n", "x", toggle_at_cursor, mapOpts)
      toggle_bound = true
    elseif toggle_bound then
      -- form → fallback 变身：space/x 是表单专属，确保解绑（键位表与直开 fallback 一致）
      top_popup:unmap("n", "<Space>")
      top_popup:unmap("n", "x")
      toggle_bound = false
    end

    -- 输入行（normal+insert）：Tab → 回到绑定题的选项区；<C-Enter> 提交；Esc 轻
    -- 交互直接取消（同内联输入缝隙 inline_input_gap 的插入模式 Esc 语义）
    input_popup:map("n", "<Tab>", focus_options_for_input, mapOpts)
    input_popup:map("i", "<Tab>", function()
      if closed or not top_popup.winid or not vim.api.nvim_win_is_valid(top_popup.winid) then
        return
      end
      focus_options_for_input()
    end, mapOpts)
    input_popup:map("n", "<C-Enter>", submit, mapOpts)
    input_popup:map("i", "<C-Enter>", submit, mapOpts)
    input_popup:map("n", "<Esc>", close, mapOpts)
    input_popup:map("i", "<Esc>", close, mapOpts)
    input_popup:map("n", "q", close, mapOpts)
    input_popup:map("n", "<C-q>", close, mapOpts)
    input_popup:map("i", "<C-q>", close, mapOpts)
  end

  -- loading 态：只绑 <Esc>（其余键一律无效，不注册任何交互键位）
  local function bind_loading_maps()
    top_popup:map("n", "<Esc>", close, mapOpts)
    input_popup:map("n", "<Esc>", close, mapOpts)
    input_popup:map("i", "<Esc>", close, mapOpts)
  end

  -- 初始光标/focus：form 落第一题建议项（无建议→首选项→✎ 行）；fallback 聚焦输入行
  local function apply_initial_focus()
    if is_form then
      focus = "options"
      local target = nil
      local q1 = questions[1]
      if q1 then
        for _, i in ipairs(q1.suggested) do
          if sel[1][i] then
            target = q_opt_first_row[1] and q_opt_first_row[1][i]
            break
          end
        end
      end
      local row = target
        or (q_opt_first_row[1] and q_opt_first_row[1][1])
        or q_pen_row[1]
        or q_first_row[1]
        or 1
      pcall(vim.api.nvim_set_current_win, top_popup.winid)
      pcall(vim.api.nvim_win_set_cursor, top_popup.winid, { row, 0 })
      sync_focus_titles()
    else
      focus_input() -- fallback：打开即聚焦输入行（插入模式，直接作答）
    end
  end

  -- 原位变身（loading → form/fallback，或旧表单 → 新表单）：
  -- 1) 停 spinner；2) 重算 spec 状态（几何恒定：宽度/高度会话期一次定死，
  --    不再调 layout:update——morph 只重渲染，零几何跳变）；3) 输入行清空并
  --    恢复可写；4) 重绑完整表单键位；5) 重渲染行 + 初始光标/focus。
  --    同一 Layout/窗口 id 不卸载重挂——dim 遮罩挂输入 buffer 生命周期，
  --    全程存活不闪。
  local function morph(spec, on_submit)
    if closed then
      return
    end
    stop_spinner()
    apply_spec(spec, on_submit)
    mode = is_form and "form" or "fallback"
    local ib = input_popup.bufnr
    if ib and vim.api.nvim_buf_is_valid(ib) then
      vim.api.nvim_set_option_value("modifiable", true, { buf = ib })
      vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "" }) -- 重问场景不残留旧草稿
    end
    bind_form_maps()
    if top_popup.winid and vim.api.nvim_win_is_valid(top_popup.winid) then
      vim.api.nvim_set_option_value("cursorline", true, { win = top_popup.winid })
    end
    render()
    apply_initial_focus()
    fire_shown() -- 显示收口：初始 focus 之后触发一次（form/fallback 都算）
  end

  if born_loading then
    bind_loading_maps()
  else
    bind_form_maps()
  end

  layout:mount()
  -- 题面缓冲标记：ft=markdown 后不能再按 filetype 定位弹窗，供测试/外部工具识别
  pcall(vim.api.nvim_buf_set_var, buf, "herder_agents_question_form", true)
  common.dim(input_popup.bufnr) -- 与 Chat 一致：mount 后挂全屏遮罩，生命周期绑输入 buffer，unmount 即散

  if born_loading then
    -- loading 骨架：输入行只读、loading 区不显示 cursorline，聚焦 loading 区
    local ib = input_popup.bufnr
    if ib and vim.api.nvim_buf_is_valid(ib) then
      vim.api.nvim_buf_set_lines(ib, 0, -1, false, { "" })
      vim.api.nvim_set_option_value("modifiable", false, { buf = ib })
    end
    if top_popup.winid and vim.api.nvim_win_is_valid(top_popup.winid) then
      vim.api.nvim_set_option_value("cursorline", false, { win = top_popup.winid })
      pcall(vim.api.nvim_set_current_win, top_popup.winid)
    end
    render_loading()
    start_spinner()
  else
    render()
    apply_initial_focus()
    fire_shown() -- 显示收口：直开 form/fallback，初始 focus 之后触发一次
  end

  -- 会话句柄：closed 经 __index 实时读取；morph 后委托当前表单的 close/closed
  local handle = setmetatable({}, {
    __index = function(_, k)
      if k == "closed" then
        return closed
      end
      return nil
    end,
  })

  function handle.set_stage(s, detail)
    if closed or mode ~= "loading" then
      return -- 迟到阶段推送（已变身/已关闭）静默丢弃
    end
    if type(s) == "string" and s ~= "" then
      stage = s
    end
    stage_detail = detail
    render_loading()
  end

  function handle.morph_to(spec, on_submit)
    if closed then
      return -- 迟到结果（用户已 esc/已让位）静默丢弃，不回调不弹窗
    end
    morph(spec, on_submit)
  end

  handle.close = close -- 幂等；<Esc> 同源；不触发任何回调

  function handle.is_closed()
    return closed
  end

  return handle
end

-- 直开表单（不经 loading）：行为与历史版本完全一致
function M.open(spec, on_submit)
  return start_ui({ spec = spec, on_submit = on_submit })
end

-- 立即弹出 loading 骨架，提取完成后经 handle.morph_to 原位变身
function M.open_loading()
  return start_ui({ loading = true })
end

return M
