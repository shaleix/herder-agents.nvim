-- question form 行模型（ui/question_form/rows.lua）—— 纯函数直测：
-- view（作答态快照）+ inner（内容宽）→ 渲染行序列；断言逐字符文本 / marks
-- 高亮组名 / kind·q·opt 元数据。测量以 nvim strdisplaywidth 为准（❓ 宽 2、
-- ✓ 宽 1、CJK 宽 2；「· 建议」6 显示宽 / 9 字节；「❓ Q1」5 显示宽 / 6 字节）。

local rows_mod = require("herder-agents.ui.question_form.rows")
local state = require("herder-agents.ui.question_form.state")

describe("question form 行模型（rows）", function()
  -- 便捷构造：题目 normalize 过、sel 按题给索引数组
  local function build(questions, sels, inner, view_extra)
    local sel = {}
    for k, list in ipairs(sels or {}) do
      sel[k] = {}
      for _, i in ipairs(list) do
        sel[k][i] = true
      end
    end
    local view = {
      is_form = true,
      questions = vim.tbl_map(state.normalize_question, questions or {}),
      sel = sel,
      raw_text = "",
    }
    for k, v in pairs(view_extra or {}) do
      view[k] = v
    end
    return rows_mod.build(view, inner)
  end

  local function texts(rows)
    local t = {}
    for i, r in ipairs(rows) do
      t[i] = r.text
    end
    return t
  end

  -- ---------------------------------------------------------------------------
  -- 折行（宽度预算：ASCII 按词、CJK 双宽硬折）
  -- ---------------------------------------------------------------------------
  it("题干按预算折行：ASCII 按词断行，续行平齐不缩进", function()
    local rows = build({ { question = "aaa bbb ccc" } }, {}, 10)
    -- head「❓ Q1」显示宽 5 → 预算 max(8, 10-5-1) = 8；题干区后恒跟一个空行
    assert.are.same({ "❓ Q1 aaa bbb", "ccc", "" }, texts(rows))
    assert.are.equal("qhead", rows[1].kind)
    assert.are.equal("header", rows[2].kind)
    assert.are.same({ { 0, 6, "HerderQFormQuestion", 50 } }, rows[1].marks)
    assert.are.same({}, rows[2].marks)
  end)

  it("CJK 双宽字符硬折：按显示宽逐字断，续行平齐不缩进", function()
    local rows = build({ { question = "这是一个很长很长的中文题干" } }, {}, 12)
    -- 13 个双宽字符、预算 8 → 每段 4 个字（显示宽 8），余 1 个字；题干区后空行
    assert.are.same({ "❓ Q1 这是一个", "很长很长", "的中文题", "干", "" }, texts(rows))
    assert.are.same(
      { "qhead", "header", "header", "header", "blank" },
      { rows[1].kind, rows[2].kind, rows[3].kind, rows[4].kind, rows[5].kind }
    )
  end)

  it("题干为空 → 整行仅节头（题干区后的空行照常）", function()
    local rows = build({ { question = "" } }, {}, 40)
    assert.are.same({ "❓ Q1", "" }, texts(rows))
    assert.are.same({ { 0, 6, "HerderQFormQuestion", 50 } }, rows[1].marks)
  end)

  -- ---------------------------------------------------------------------------
  -- 选项行：✓ 字形前缀 vs 2 空格占位；选项续行 2 空格缩进
  -- ---------------------------------------------------------------------------
  it("选中 ✓ 前缀（HerderQFormOn）vs 未选中 2 空格占位；CJK 选项折行续行缩进", function()
    local rows = build({ { question = "Q?", options = { "中文选项文本" } } }, { { 1 } }, 12)
    -- opt_w = 12-2 = 10 → 6 字双宽词硬折成 5+1 字（显示宽 10 + 2）
    assert.are.same({ "❓ Q1 Q?", "", "✓ 中文选项文", "  本" }, texts(rows))
    assert.are.equal("option", rows[3].kind)
    assert.are.equal(1, rows[3].q)
    assert.are.equal(1, rows[3].opt)
    assert.are.same({ { 0, 3, "HerderQFormOn" } }, rows[3].marks, "✓ 字形（3 字节）压 HerderQFormOn")
    assert.are.equal("option", rows[4].kind)
    assert.are.equal(1, rows[4].opt)
    assert.are.same({}, rows[4].marks, "续行无高亮")

    -- 未选中：等宽 2 空格占位，文字列对齐、无高亮
    rows = build({ { question = "Q?", options = { "中文选项文本" } } }, { {} }, 12)
    assert.are.same({ "❓ Q1 Q?", "", "  中文选项文", "  本" }, texts(rows))
    assert.are.same({}, rows[3].marks)
  end)

  -- ---------------------------------------------------------------------------
  -- 建议标记：贴文本末尾（Comment 区间）放不下则独占一行
  -- ---------------------------------------------------------------------------
  it("建议标记放得下 → 追加在文本末尾，Comment 区间平移", function()
    local rows = build({ { question = "Q?", options = { "alpha", "beta" }, suggested = { 1 } } }, { {} }, 40)
    assert.are.same({ "❓ Q1 Q?", "", "  alpha  · 建议", "  beta" }, texts(rows))
    -- mrange = { #“alpha”=5, +11 字节 }，off = 2（未选中占位）
    assert.are.same({ { 7, 18, "Comment" } }, rows[3].marks)
    assert.are.same({}, rows[4].marks, "非建议选项无标记")
  end)

  it("建议标记放不下 → 独占一行（缩进对齐文本列）", function()
    -- opt_w = 8，选项「abcdefgh」显示宽 8 已占满，标记（显示宽 6）加不下
    local rows = build({ { question = "Q?", options = { "abcdefgh" }, suggested = { 1 } } }, { {} }, 10)
    assert.are.same({ "❓ Q1 Q?", "", "  abcdefgh", "  · 建议" }, texts(rows))
    assert.are.equal("option", rows[4].kind)
    assert.are.equal(1, rows[4].opt)
    assert.are.same({ { 2, 11, "Comment" } }, rows[4].marks, "标记行 Comment 区间 = 「· 建议」9 字节")
  end)

  -- ---------------------------------------------------------------------------
  -- 分割线 / desc
  -- ---------------------------------------------------------------------------
  it("多题分节：分割线宽度 = inner、空行对称包住、q 指向下一节", function()
    local rows = build({ { question = "A?" }, { question = "B?" } }, { {}, {} }, 8)
    -- 每题节头块后恒跟一个空行（题干区与选项区分隔，无选项也保留）
    assert.are.same({ "❓ Q1 A?", "", "", "--------", "", "❓ Q2 B?", "" }, texts(rows))
    assert.are.equal("divider", rows[4].kind)
    assert.are.equal(2, rows[4].q)
    assert.are.same({ { 0, 8, "HerderQFormDivider" } }, rows[4].marks)
    assert.are.equal("qhead", rows[6].kind)
  end)

  it("desc 说明行：Comment 压暗、紧跟空行、折满 inner；desc 为空不产生行", function()
    local rows = build({ { question = "Q?", options = {}, desc = "note here" } }, { {} }, 40)
    assert.are.same({ "❓ Q1 Q?", "", "", "note here" }, texts(rows))
    assert.are.equal("desc", rows[4].kind)
    assert.are.same({ { 0, 9, "Comment" } }, rows[4].marks)

    rows = build({ { question = "Q?", options = {} } }, { {} }, 40)
    assert.are.same({ "❓ Q1 Q?", "" }, texts(rows), "desc 缺省空串 → 无 desc 行")
  end)

  -- ---------------------------------------------------------------------------
  -- fallback 原文 / 空行兜底
  -- ---------------------------------------------------------------------------
  it("fallback raw_text：\\r 剥离后逐行折行（kind=raw、无 q/opt）", function()
    local rows = build(nil, nil, 40, { is_form = false, raw_text = "line one\r\nline two" })
    assert.are.same({ "line one", "line two" }, texts(rows))
    for _, r in ipairs(rows) do
      assert.are.equal("raw", r.kind)
      assert.are.equal(nil, r.q)
      assert.are.equal(nil, r.opt)
      assert.are.same({}, r.marks)
    end

    rows = build(nil, nil, 4, { is_form = false, raw_text = "aaaa bb" })
    assert.are.same({ "aaaa", "bb" }, texts(rows), "超预算行同样折行")
  end)

  it("空内容兜底：form 无题 / fallback 空文本 → 单个空白 raw 行", function()
    local rows = build({}, {}, 40)
    assert.are.equal(1, #rows)
    assert.are.equal("", rows[1].text)
    assert.are.equal("raw", rows[1].kind)

    rows = build(nil, nil, 40, { is_form = false, raw_text = "" })
    assert.are.equal(1, #rows)
    assert.are.equal("", rows[1].text)
    assert.are.equal("raw", rows[1].kind)
  end)

  -- ---------------------------------------------------------------------------
  -- 测量原语与标记常量归属（shell 的 loading 居中/题干预览同源复用）
  -- ---------------------------------------------------------------------------
  it("导出测量原语 dw/take_dw/wrap_dw 与 MARKER（双宽感知）", function()
    assert.are.equal("· 建议", rows_mod.MARKER)
    assert.are.equal(8, rows_mod.dw("中文三字"))
    assert.are.equal(2, rows_mod.dw("❓"))
    assert.are.equal("中文", rows_mod.take_dw("中文abc", 4), "双宽字符整字取舍")
    assert.are.same({ "aaaa", "bb" }, rows_mod.wrap_dw("aaaa bb", 4))
  end)
end)
