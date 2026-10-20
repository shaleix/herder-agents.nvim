-- Agent 提问表单 · 作答状态机（纯函数集，表进表出）：弹窗 shell
-- （ui/question_form/init.lua）按作答语义调用本模块。require 零副作用——
-- 不依赖 nui/config，无任何 vim.* 调用，headless 可直接 require 断言。
--
-- 状态形状（本模块生产、shell 持有）：
--   questions[k]  = normalize_question 产物（n_base = 原选项数，固定；Enter 生成的
--                   自定义选项文本物化在 options[n_base+1]，n_base 不变）
--   sel[k]        = { [选项索引] = true }（自定义选项索引 = n_base+1 同权）
--   custom_opt[k] = { text }（Enter 生成/更新的正式自定义选项）
--   drafts[k]     = 输入行草稿（trim 后）
--   raw_text      = fallback 原文
--   is_form / nq  = 形态与题数
--
-- toggle/set_custom/unanswered 以「最小状态表」入参（只取用到的键，表内原地
-- 修改并把同一张表返回，表进表出）；apply_spec 入参旧态快照、返回全新状态表。
local M = {}

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

-- 单题 spec 归一化：question/options 字符串化、suggested 越界过滤（保持传入顺序，
-- radio 初始选中取第一个有效建议）；question 做防御性前缀剥离——label 非空且
-- question 以 label 开头、后跟分隔符 [-–—:：.、)] 与空白时剥掉这一处前导
-- （system_prompt 已要求编号进 label，这里兜底 LLM 漏剥；剥后为空则不剥；
-- label 为空不动），其余逐字不改写；options 一律逐字不动；
-- desc 仅 tostring 归一（缺省 ""），不做任何清洗，渲染层原样展示；
-- label 仅 tostring 归一（缺省 ""）——原始标号元数据，驱动节头 `❓ <label>`、
-- 提交块头 / 未答拦截提示 / 输入行标题。n_base = 原选项数（固定）：Enter 生成
-- 的自定义选项恒追加在索引 n_base+1，suggested 越界过滤只认原选项（自定义
-- 选项永不带「· 建议」标记）
function M.normalize_question(q)
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
  item.n_base = #item.options -- 原选项数固定：自定义选项索引恒为 n_base+1
  return item
end

-- spec 解析 + 会话状态重算（纯函数）：open 直开与 morph 共用的核心——shell 只做
-- 旧态快照入参、新态写回与 shell 专属字段（on_submit/submitted/focus/input_q/
-- leave_row）复位，几何不在此重算。
--   spec：M.open 契约的 spec（form 多题 / 旧扁平单题 / fallback）
--   old：变身前状态快照 { is_form, questions, sel, custom_opt, drafts }（loading
--        直开或旧态无题表时传空表即可，天然全新作答）
-- form→form 重问延续：按题干逐字匹配，同题干的旧题继承选中/自定义选项/草稿
-- （原选项位需索引与文本都相同才继承选中；自定义选项选中映射到新「原选项数+1」；
-- radio 只保最低已选项）；未延续的题按 suggested 全新作答——单选取第一个有效
-- 建议（无则初始无选中），多选取全部 suggested。
function M.apply_spec(spec, old)
  spec = spec or {}
  old = old or {}

  local old_pool = {}
  if old.is_form then
    for j, oq in ipairs(old.questions or {}) do
      old_pool[#old_pool + 1] = { q = oq, sel = old.sel[j] or {}, co = old.custom_opt[j], draft = old.drafts[j] or "" }
    end
  end
  local function take_old(stem)
    for idx, e in ipairs(old_pool) do
      if e.q.question == stem then
        old_pool[idx] = old_pool[#old_pool]
        old_pool[#old_pool] = nil
        return e
      end
    end
    return nil
  end

  local is_form = spec.mode ~= "fallback"
  local questions, raw_text = {}, ""
  local sel, custom_opt, drafts = {}, {}, {}
  if is_form then
    if type(spec.questions) == "table" and #spec.questions > 0 then
      for _, q in ipairs(spec.questions) do
        questions[#questions + 1] = M.normalize_question(q)
      end
    elseif type(spec.options) == "table" or type(spec.question) == "string" then
      -- 旧扁平单题 spec：等价 questions={一条}（N=1 输出与历史完全一致）
      questions[1] = M.normalize_question(spec)
    end
  else
    raw_text = tostring(spec.raw_text or "")
  end

  for k, q in ipairs(questions) do
    local match = take_old(q.question)
    local s = {}
    if match then
      -- 延续旧作答：原选项位文本相同才继承；自定义选项（含文本物化）延续
      local oldq = match.q
      local keys = {}
      for i in pairs(match.sel) do
        keys[#keys + 1] = i
      end
      table.sort(keys)
      local lowest = nil
      for _, i in ipairs(keys) do
        local keep = nil
        if i <= oldq.n_base and i <= q.n_base and oldq.options[i] == q.options[i] then
          keep = i
        elseif match.co and i == oldq.n_base + 1 then
          keep = q.n_base + 1
        end
        if keep then
          s[keep] = true
          if not lowest or keep < lowest then
            lowest = keep
          end
        end
      end
      if not q.multiple then
        s = lowest and { [lowest] = true } or {}
      end
      if match.co then
        custom_opt[k] = match.co
        q.options[q.n_base + 1] = match.co.text
      end
      drafts[k] = match.draft
    end
    if next(s) == nil then
      -- 未延续（新题/旧题未作答）：suggested 初选——单选取第一个有效建议
      -- （无则初始无选中），多选取全部 suggested
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
    end
    sel[k] = s
    if drafts[k] == nil then
      drafts[k] = ""
    end
  end

  return {
    is_form = is_form,
    questions = questions,
    nq = #questions,
    raw_text = raw_text,
    sel = sel,
    custom_opt = custom_opt,
    drafts = drafts,
  }
end

-- <Space>/x 切换语义（纯函数）：st = { questions, sel }；radio 恒恰一项、对已
-- 选项重复切换不反选（整表换选）；checkbox 增删（自定义选项同权，索引即传入值）
function M.toggle(st, k, i)
  local q = st.questions and st.questions[k]
  local sel = st.sel
  if not q then
    return st
  end
  if q.multiple then
    sel[k] = sel[k] or {}
    if sel[k][i] then
      sel[k][i] = nil
    else
      sel[k][i] = true
    end
  else
    sel[k] = { [i] = true } -- radio：始终恰一项；对已选项 space 不反选
  end
  return st
end

-- Enter 提交自定义的升级语义（纯函数）：st = { questions, sel, custom_opt, drafts }。
-- 为第 k 题生成/更新一个正式选项——追加在原选项之后（索引恒 q.n_base+1；已存在
-- 则原位更新文本、选中状态保持不变，编辑语义）；新建即选中：radio 排他换选
-- （原选中取消）、checkbox 与已选并存勾选；文本同步物化进 q.options[n_base+1]
-- 供渲染与 compose 直接消费；草稿与已提交内容对齐（再次预填同一文本）
function M.set_custom(st, k, text)
  local q = st.questions and st.questions[k]
  if not q then
    return st
  end
  local idx = q.n_base + 1
  local existed = st.custom_opt[k] ~= nil
  st.custom_opt[k] = { text = text }
  q.options[idx] = text
  st.drafts[k] = text
  if not existed then
    if q.multiple then
      st.sel[k] = st.sel[k] or {}
      st.sel[k][idx] = true
    else
      st.sel[k] = { [idx] = true } -- radio：新建即选中，原选中取消
    end
  end
  return st
end

-- 未答拦截点名（纯函数）：st = { questions, sel }。返回所有「0 选中」题的
-- { k, label } 数组（保持题序）——label 非空用原始标号，否则回退「第 k 题」
--（与 submit 拦截提示文案一致）；自定义选项与普通选项同权计入已答，输入行
-- 未提交的草稿不算
function M.unanswered(st)
  local out = {}
  local questions, sel = st.questions or {}, st.sel or {}
  for k, q in ipairs(questions) do
    if next(sel[k] or {}) == nil then
      out[#out + 1] = {
        k = k,
        label = q.label ~= "" and q.label or ("第 " .. k .. " 题"),
      }
    end
  end
  return out
end

return M
