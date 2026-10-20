-- question form 作答状态机（ui/question_form/state.lua）—— 纯函数直测：
-- 表进表出、无 vim/nui 依赖，headless 直接 require 断言（模块 require 零副作用）

local state = require("herder-agents.ui.question_form.state")

describe("question form 作答状态（state）", function()
  -- sel 表 → 排序索引数组（断言用：忽略 pairs 顺序）
  local function keys(sel)
    local ks = {}
    for i in pairs(sel) do
      ks[#ks + 1] = i
    end
    table.sort(ks)
    return ks
  end
  -- 索引数组 → sel 表
  local function selmap(list)
    local t = {}
    for _, i in ipairs(list) do
      t[i] = true
    end
    return t
  end
  -- 便捷状态表（normalize 过的题表 + 空 sel/custom_opt/drafts）
  local function mkstate(questions)
    return {
      questions = vim.tbl_map(state.normalize_question, questions or {}),
      sel = {},
      custom_opt = {},
      drafts = {},
    }
  end

  -- ---------------------------------------------------------------------------
  -- normalize_question：防御性前缀剥离 / suggested 越界过滤 / n_base
  -- ---------------------------------------------------------------------------
  describe("normalize_question", function()
    it("防御性前缀剥离：label 开头 + 分隔符 run 一次剥净（多分隔符不残留）", function()
      local cases = {
        { label = "Q2", question = "Q2 - Deploy how?", want = "Deploy how?" },
        { label = "Q2", question = "Q2：Deploy how?", want = "Deploy how?" },
        { label = "Q2", question = "Q2 — Deploy how?", want = "Deploy how?" },
        { label = "3", question = "3、选择部署方式", want = "选择部署方式" },
        { label = "A", question = "A) Choose one:", want = "Choose one:" },
        { label = "1.", question = "1. Pick:", want = "Pick:" },
        -- 最长 run 一起剥：不留第二个分隔符
        { label = "Q1", question = "Q1 --  two separators", want = "two separators" },
        -- 剥后为空（题干就是标号本身）→ 不剥
        { label = "Q1", question = "Q1", want = "Q1" },
        { label = "Q1", question = "Q1 -", want = "Q1 -" },
        -- label 为空 / 前缀不匹配 → 不动
        { label = "", question = "Q1 - foo", want = "Q1 - foo" },
        { label = "Q9", question = "Totally different", want = "Totally different" },
      }
      for _, c in ipairs(cases) do
        local item = state.normalize_question({ label = c.label, question = c.question })
        assert.are.equal(c.want, item.question, ("label=%q question=%q"):format(c.label, c.question))
      end
    end)

    it("字段归一：tostring / 缺省空串 / multiple 严格 ==true / options 逐字", function()
      local item = state.normalize_question({})
      assert.are.equal("", item.question)
      assert.are.equal("", item.label)
      assert.are.equal("", item.desc)
      assert.are.falsy(item.multiple)
      assert.are.same({}, item.options)
      assert.are.same({}, item.suggested)
      assert.are.equal(0, item.n_base)

      item = state.normalize_question({ question = 42, label = 7, desc = "d", multiple = "yes" })
      assert.are.equal("42", item.question)
      assert.are.equal("7", item.label)
      assert.are.falsy(item.multiple, 'multiple 只有 true 才为真（"yes" 不算）')

      item = state.normalize_question({ options = { "a", 2 }, desc = nil })
      assert.are.same({ "a", "2" }, item.options)
      assert.are.equal(2, item.n_base)

      -- 非法入参不炸
      assert.are.equal(0, state.normalize_question(nil).n_base)
      assert.are.equal(0, state.normalize_question("nope").n_base)
    end)

    it("suggested 越界/非数字过滤，n_base = 原选项数（自定义选项恒 n_base+1）", function()
      local item = state.normalize_question({
        question = "Q?",
        options = { "a", "b", "c" },
        suggested = { 2, 5, "x", 1 },
      })
      assert.are.same({ 2, 1 }, item.suggested, "保持传入顺序，越界与非数字剔除")
      assert.are.same({ [2] = true, [1] = true }, item.suggested_set)
      assert.are.equal(3, item.n_base)
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- apply_spec：spec 解析 + form→form 延续匹配 + suggested 初选
  -- ---------------------------------------------------------------------------
  describe("apply_spec", function()
    it("旧扁平单题 spec 等价 questions={一条}；fallback 收 raw_text；空 spec 全空", function()
      local st = state.apply_spec({ mode = "form", question = "Solo?", options = { "a" } }, nil)
      assert.truthy(st.is_form)
      assert.are.equal(1, st.nq)
      assert.are.equal("Solo?", st.questions[1].question)
      assert.are.same({ "a" }, st.questions[1].options)

      st = state.apply_spec({ mode = "fallback", raw_text = "raw body" }, nil)
      assert.falsy(st.is_form)
      assert.are.equal(0, st.nq)
      assert.are.equal("raw body", st.raw_text)

      st = state.apply_spec({ mode = "fallback", raw_text = 99 }, nil)
      assert.are.equal("99", st.raw_text, "raw_text 仅 tostring 归一")

      st = state.apply_spec(nil, nil)
      assert.truthy(st.is_form)
      assert.are.equal(0, st.nq)
      assert.are.equal("", st.raw_text)
    end)

    it("延续：同题干且索引+文本都相同才继承选中；文本变了不继承", function()
      local old = state.apply_spec({
        mode = "form",
        questions = {
          { label = "Q1", question = "Deploy?", options = { "Docker", "bare" }, multiple = true },
        },
      }, nil)
      old.sel[1] = { [2] = true }

      -- 同题干 + 同选项文本：继承
      local st = state.apply_spec({
        mode = "form",
        questions = { { question = "Deploy?", options = { "Docker", "bare" }, multiple = true } },
      }, old)
      assert.are.same({ 2 }, keys(st.sel[1]))

      -- 同题干但选项文本改写：原选项位不继承（旧选中只覆盖原索引）
      st = state.apply_spec({
        mode = "form",
        questions = { { question = "Deploy?", options = { "Docker", "bare metal" }, multiple = true } },
      }, old)
      assert.are.same({}, keys(st.sel[1]))
    end)

    it("延续：自定义选项重映射到新 n_base+1，文本物化、custom_opt/drafts 随行", function()
      local old = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b" }, multiple = true } },
      }, nil)
      old = state.set_custom(old, 1, "手工补充") -- 选中 { 3 }、custom_opt[1]、drafts[1]
      old.sel[1] = { [1] = true, [3] = true }

      -- 新 spec 原选项数不变（2）：普通位 1 继承，自定义位 3 → 新 n_base+1 = 3
      local st = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b" }, multiple = true } },
      }, old)
      assert.are.same({ 1, 3 }, keys(st.sel[1]))
      assert.are.equal("手工补充", st.questions[1].options[3], "自定义文本物化在 options[n_base+1]")
      assert.are.same({ text = "手工补充" }, st.custom_opt[1])
      assert.are.equal("手工补充", st.drafts[1])

      -- 新 spec 原选项数变多（3）：自定义位重映射到 4
      st = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b", "c" }, multiple = true } },
      }, old)
      assert.are.same({ 1, 4 }, keys(st.sel[1]))
      assert.are.equal("手工补充", st.questions[1].options[4])
    end)

    it("延续：radio 只保最低已选项；自定义存在但未选中时仍延续文本、不加选中", function()
      -- 构造 radio 旧态多选（延续匹配路径显式处理该形状）
      local old = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b" }, multiple = false } },
      }, nil)
      old = state.set_custom(old, 1, "custom text") -- radio 新建即选中 { 3 }
      old.sel[1] = { [2] = true, [3] = true } -- 人为构造多选：radio 延续只保最低

      local st = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b" }, multiple = false } },
      }, old)
      assert.are.same({ 2 }, keys(st.sel[1]), "radio 延续收敛到最低 kept 索引")

      -- custom 存在但未选中：文本/草稿延续，选中不凭空出现
      old.sel[1] = { [1] = true } -- 只选普通位，自定义未选中
      st = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a", "b" }, multiple = true } },
      }, old)
      assert.are.same({ 1 }, keys(st.sel[1]))
      assert.are.equal("custom text", st.questions[1].options[3])
      assert.are.same({ text = "custom text" }, st.custom_opt[1])
    end)

    it("延续：题干不匹配的题全新作答；匹配但旧态未作答也走 suggested 初选", function()
      local old = state.apply_spec({
        mode = "form",
        questions = {
          { question = "Old?", options = { "x" }, multiple = true },
        },
      }, nil)
      old.sel[1] = { [1] = true }
      old.drafts[1] = "old draft"

      local st = state.apply_spec({
        mode = "form",
        questions = {
          { question = "New?", options = { "p", "q" }, multiple = false, suggested = { 2, 1 } },
        },
      }, old)
      assert.are.same({ 2 }, keys(st.sel[1]), "新题：单选取第一个有效建议")
      assert.are.equal("", st.drafts[1], "未延续题草稿为空")

      -- 同题干但旧态零选中 → 落入 suggested 初选（不是空选）
      old.sel[1] = {}
      st = state.apply_spec({
        mode = "form",
        questions = {
          { question = "Old?", options = { "x" }, multiple = false, suggested = { 1 } },
        },
      }, old)
      assert.are.same({ 1 }, keys(st.sel[1]))
    end)

    it("延续：旧态 is_form=false（fallback 变身）不延续，全部新作答", function()
      local old = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a" }, multiple = true, suggested = { 1 } } },
      }, nil)
      old.sel[1] = { [1] = true }
      old.is_form = false -- 模拟旧表单已是 fallback 态

      local st = state.apply_spec({
        mode = "form",
        questions = { { question = "R?", options = { "a" }, multiple = true, suggested = { 1 } } },
      }, old)
      assert.are.same({ 1 }, keys(st.sel[1]), "suggested 初选生效（无延续）")
      assert.are.equal("", st.drafts[1])
    end)

    it("fresh 初选：多选取全部 suggested；无建议则空；drafts 缺省归空串", function()
      local st = state.apply_spec({
        mode = "form",
        questions = {
          { question = "M?", options = { "a", "b", "c" }, multiple = true, suggested = { 1, 3 } },
          { question = "S?", options = { "a", "b" }, multiple = false, suggested = { 2, 1 } },
          { question = "N?", options = { "a" }, multiple = true },
          { question = "E?", options = { "a" }, multiple = false },
        },
      }, nil)
      assert.are.same({ 1, 3 }, keys(st.sel[1]))
      assert.are.same({ 2 }, keys(st.sel[2]), "单选只取第一个有效建议")
      assert.are.same({}, keys(st.sel[3]))
      assert.are.same({}, keys(st.sel[4]))
      assert.are.same({ "", "", "", "" }, st.drafts)
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- compose / compose_questions：提交文本组装
  -- ---------------------------------------------------------------------------
  describe("compose / compose_questions", function()
    it("compose：按选项顺序稳定输出选中项原文 + 自定义行原样", function()
      assert.are.equal("a\nc", state.compose({ "a", "b", "c" }, { 1, 3 }, ""))
      assert.are.equal("a\nc\n注", state.compose({ "a", "b", "c" }, { 3, 1 }, "注"), "与传入顺序无关")
      assert.are.equal("", state.compose({ "a" }, {}, nil))
      assert.are.equal("42", state.compose({ 42 }, { 1 }, nil), "非字符串选项 tostring 输出")
    end)

    it("N=1：无前缀（带 label 也不例外），与 compose 完全一致", function()
      local out = state.compose_questions({ { label = "Q7", options = { "x", "y" } } }, { [1] = { 2 } }, {})
      assert.are.equal("y", out)
      out = state.compose_questions({ { label = "Q7", options = { "x", "y" } } }, { [1] = { 1 } }, { [1] = "c" })
      assert.are.equal("x\nc", out)
      assert.are.equal("", state.compose_questions({}, nil, nil), "空表 → 空串")
    end)

    it("N>1：label 块头（无 label 回退位置 Qk）、块间空行、无尾随空行", function()
      local out = state.compose_questions({
        { label = "Q3", options = { "a", "b" } },
        { label = "", options = { "c", "d" } },
        { label = "Q9", options = { "e", "f" } },
      }, { [1] = { 2 }, [2] = { 1 }, [3] = {} }, { [2] = "note" })
      assert.are.equal("Q3:\nb\n\nQ2:\nc\nnote\n\nQ9:", out)
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- toggle：radio / checkbox 切换语义
  -- ---------------------------------------------------------------------------
  describe("toggle", function()
    it("checkbox：增删切换（自定义选项同权）", function()
      local st = mkstate({ { question = "M?", options = { "a", "b" }, multiple = true } })
      state.toggle(st, 1, 1)
      assert.are.same({ 1 }, keys(st.sel[1]))
      state.toggle(st, 1, 2)
      assert.are.same({ 1, 2 }, keys(st.sel[1]))
      state.toggle(st, 1, 1) -- 再切反选
      assert.are.same({ 2 }, keys(st.sel[1]))
      state.toggle(st, 1, 3) -- 自定义选项索引（n_base+1）同权
      assert.are.same({ 2, 3 }, keys(st.sel[1]))
    end)

    it("radio：恒恰一项、重复切换不反选、换选即替换", function()
      local st = mkstate({ { question = "S?", options = { "a", "b" }, multiple = false } })
      state.toggle(st, 1, 1)
      assert.are.same({ 1 }, keys(st.sel[1]))
      state.toggle(st, 1, 1) -- 对已选项 space 不反选
      assert.are.same({ 1 }, keys(st.sel[1]))
      state.toggle(st, 1, 2) -- 换选：原选中取消
      assert.are.same({ 2 }, keys(st.sel[1]))
    end)

    it("无该题时安全 no-op（返回原状态表）", function()
      local st = mkstate({ { question = "S?", options = { "a" }, multiple = false } })
      assert.are.equal(st, state.toggle(st, 9, 1))
      assert.are.same({}, st.sel)
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- set_custom：自定义答案升级（生成/原位更新/选中语义）
  -- ---------------------------------------------------------------------------
  describe("set_custom", function()
    it("radio 新建即选中（排他换选），文本物化 + 草稿对齐", function()
      local st = mkstate({ { question = "S?", options = { "a", "b" }, multiple = false } })
      state.toggle(st, 1, 1)
      state.set_custom(st, 1, "手工答案")
      assert.are.equal("手工答案", st.questions[1].options[3], "物化在 options[n_base+1]")
      assert.are.same({ text = "手工答案" }, st.custom_opt[1])
      assert.are.same({ 3 }, keys(st.sel[1]), "radio：原选中取消、自定义即选中")
      assert.are.equal("手工答案", st.drafts[1])
    end)

    it("checkbox 新建与已选并存", function()
      local st = mkstate({ { question = "M?", options = { "a", "b" }, multiple = true } })
      state.toggle(st, 1, 1)
      state.set_custom(st, 1, "extra")
      assert.are.same({ 1, 3 }, keys(st.sel[1]))
    end)

    it("re-edit：原位更新文本、选中状态保持不变（编辑语义）", function()
      local st = mkstate({
        { question = "S?", options = { "a", "b" }, multiple = false },
        { question = "M?", options = { "a", "b" }, multiple = true },
      })
      state.set_custom(st, 1, "v1")
      state.set_custom(st, 2, "v1")
      -- radio：编辑后选中保持（不重新触发排他）
      state.set_custom(st, 1, "v2")
      assert.are.equal("v2", st.questions[1].options[3])
      assert.are.same({ 3 }, keys(st.sel[1]))
      -- checkbox：编辑后勾选保持
      state.set_custom(st, 2, "v2")
      assert.are.equal("v2", st.questions[2].options[3])
      assert.are.same({ 3 }, keys(st.sel[2]))
      -- 编辑成未选中态也保持（existed 分支完全不碰 sel）
      st.sel[1] = {}
      state.set_custom(st, 1, "v3")
      assert.are.same({}, keys(st.sel[1]))
      assert.are.equal("v3", st.drafts[1])
    end)
  end)

  -- ---------------------------------------------------------------------------
  -- unanswered：未答拦截点名（label 或 第 k 题）
  -- ---------------------------------------------------------------------------
  describe("unanswered", function()
    it("返回未答题的 { k, label }（label 非空用原始标号，否则回退第 k 题）", function()
      local st = mkstate({
        { label = "Q5", question = "A?", options = { "a" }, multiple = true },
        { label = "", question = "B?", options = { "a" }, multiple = true },
        { label = "", question = "C?", options = { "a" }, multiple = true },
      })
      state.toggle(st, 2, 1) -- 第 2 题已答
      local missing = state.unanswered(st)
      assert.are.same({ { k = 1, label = "Q5" }, { k = 3, label = "第 3 题" } }, missing)
    end)

    it("全部已答 → 空表；自定义选项选中计入已答", function()
      local st = mkstate({ { question = "A?", options = { "a" }, multiple = true } })
      assert.are.equal(1, #state.unanswered(st))
      state.set_custom(st, 1, "x") -- 自定义选项同权计入已答
      assert.are.same({}, state.unanswered(st))
    end)
  end)
end)
