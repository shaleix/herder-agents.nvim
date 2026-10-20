-- Agent 提问表单 · 行模型（纯函数）：作答态 + 固定内容宽度 → 渲染行序列。
-- 每行 { text, marks = { {起始字节, 结束字节, hl组[, 优先级]} }, kind, q, opt }；
-- marks 只携带高亮组名字符串（HerderQFormQuestion / HerderQFormOn /
-- HerderQFormDivider / Comment）——纯数据零副作用，弹窗 shell 渲染时才落
-- extmark。唯一例外是测量 dw 经 vim.fn.strdisplaywidth（plenary 本就跑在
-- nvim 内），其余无任何 vim 依赖，spec 直测。
local M = {}

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

-- 建议标记（渲染在选项文本末尾，放不下则独占一行；Comment 灰）；
-- 只可能落在原选项上——Enter 生成的自定义选项永不带建议标记
M.MARKER = "· 建议"

-- 供 shell 复用的测量原语（loading 居中/截断、拦截提示题干预览同源）
M.dw = dw
M.take_dw = take_dw
M.wrap_dw = wrap_dw

-- 按 \n 纯文本分行：空文本 → { "" }（与 vim.split plain=true 同构，本地实现
-- 保持本模块除测量外零 vim 调用）
local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

-- 行模型：每行 { text, marks = { {起始字节, 结束字节, hl组, 优先级?} }, kind, q, opt }。
-- 题面文本（节头/题干/fallback 原文）不再整行压 extmark——filetype=markdown 的
-- 语法高亮直接生效（ATX 节头/代码块/加粗等与手工折行共存）；extmark 只用于
-- 结构性字形（节头粗体/选项框 ✓/分割线）。
--   view  = { is_form, questions, sel, raw_text }（shell 当前作答态快照）
--   inner = 上框内容行宽（折行/分割线统一预算）
function M.build(view, inner)
  local is_form = view.is_form
  local questions = view.questions or {}
  local sel = view.sel or {}
  local raw_text = view.raw_text or ""
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
      -- 节头与题干同行：`❓ <标号> <题干首段>`（label 非空用原始标号，否则回退
      -- 位置序号 Qk；N=1 同样有）。「❓ 标号」前缀压 HerderQFormQuestion
      --（Title 色）extmark、低优先级（50）兜底——不再用 markdown ATX 记号；
      -- 题干首段折行预算扣除节头宽 + 连接空格，续行平齐不缩进；不参与
      -- space 选择；题干为空则整行仅节头
      local head_label = q.label ~= "" and q.label or ("Q" .. k)
      local head = "❓ " .. head_label
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
          local mtext = "  " .. M.MARKER
          local last = osegs[#osegs]
          if dw(last) + dw(mtext) <= opt_w then
            osegs[#osegs] = last .. mtext
            mrange = { #last, #osegs[#osegs] }
          else
            osegs[#osegs + 1] = M.MARKER
            mrange = { 0, #M.MARKER }
          end
        end
        for si, seg in ipairs(osegs) do
          local text, marks, off
          if si == 1 then
            local on = sel[k] and sel[k][i] == true
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
      -- desc 说明行（仅展示、不进提交文本）：渲染在选项区之后（建议/选项/
      -- 自定义选项全部收束后的节尾），与上方选项区空一行分隔；Comment 压暗
      --（与「· 建议」标记/图例同语系），折满 inner、续行平齐不缩进（与题干
      -- 续行同策略）；不参与 space 选择与 j/k 导航；desc 为空 → 不产生额外行
      if q.desc ~= "" then
        add("", {}, "blank", k, nil)
        for _, seg in ipairs(wrap_dw(q.desc, inner)) do
          add(seg, { { 0, #seg, "Comment" } }, "desc", k, nil)
        end
      end
    end
  else
    for _, line in ipairs(split_lines((raw_text:gsub("\r", "")))) do
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

return M
