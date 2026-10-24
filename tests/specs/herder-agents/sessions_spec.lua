-- sessions（prompt 文件附件状态机）—— 纯状态直测：
-- add/read/drop/list/clear 全走 current_session()，无 UI 依赖，headless 直接断言。
-- 路径归一语义：utils.get_relative_path 只在路径以 cwd 开头时剥掉 cwd 前缀。

local sessions = require("herder-agents.sessions")

describe("sessions 附件状态（entries 有序表）", function()
  -- 相对路径 → 绝对路径（get_relative_path 剥 cwd 前缀的逆操作）
  local function abs(rel)
    return vim.fn.getcwd() .. "/" .. rel
  end

  local function session()
    return sessions.current_session()
  end

  it("add→list 保插入顺序；重复 add 不产生重复条目", function()
    session():clear_files()
    session():add_files({ "a.lua", "b.lua", "c.lua" })
    assert.are.same({ added = { "a.lua", "b.lua", "c.lua" }, readonly = {} }, session():list_files())

    -- 绝对路径传入同一文件（归一后同路径）→ 去重，不新增
    session():add_files({ abs("b.lua") })
    assert.are.same({ added = { "a.lua", "b.lua", "c.lua" }, readonly = {} }, session():list_files())
  end)

  it("add 后 read 同一文件 → 翻成 readonly，原插入位置不动", function()
    session():clear_files()
    session():add_files({ "x.lua", "y.lua" })
    session():read_files({ "x.lua" })

    local files = session():list_files()
    assert.are.same({ "y.lua" }, files.added)
    assert.are.same({ "x.lua" }, files.readonly)

    -- 再 add 回来：x 回到 added 且仍在最前（单一有序 entries，翻 mode 不挪位）
    session():add_files({ abs("x.lua") })
    assert.are.same({ added = { "x.lua", "y.lua" }, readonly = {} }, session():list_files())

    -- 重复 read 也不产生重复条目
    session():read_files({ "y.lua", "y.lua" })
    assert.are.same({ added = { "x.lua" }, readonly = { "y.lua" } }, session():list_files())
  end)

  it("read 后 add → 翻回 added，顺序保持", function()
    session():clear_files()
    session():read_files({ "r1.lua", "r2.lua" })
    assert.are.same({ added = {}, readonly = { "r1.lua", "r2.lua" } }, session():list_files())

    session():add_files({ "r1.lua" })
    local files = session():list_files()
    assert.are.same({ "r1.lua" }, files.added)
    assert.are.same({ "r2.lua" }, files.readonly)

    -- 翻回后原位次序仍先于新追加项
    session():add_files({ "r2.lua", "r3.lua" })
    assert.are.same({ added = { "r1.lua", "r2.lua", "r3.lua" }, readonly = {} }, session():list_files())
  end)

  it("drop 归一化：存的相对路径、传绝对路径（或反之）都能删掉", function()
    session():clear_files()
    -- 相对路径存入，绝对路径 drop
    session():add_files({ "lua/init.lua" })
    session():drop_files({ abs("lua/init.lua") })
    assert.are.same({ added = {}, readonly = {} }, session():list_files())

    -- 绝对路径存入（归一成相对存储），相对路径 drop
    session():read_files({ abs("lua/utils.lua") })
    assert.are.same({ added = {}, readonly = { "lua/utils.lua" } }, session():list_files())
    session():drop_files({ "lua/utils.lua" })
    assert.are.same({ added = {}, readonly = {} }, session():list_files())

    -- 不存在的路径 drop 是安全 no-op
    session():add_files({ "keep.lua" })
    session():drop_files({ "nope.lua" })
    assert.are.same({ added = { "keep.lua" }, readonly = {} }, session():list_files())
  end)

  it("drop 对 added / readonly 两种 mode 都生效；clear 清空两表", function()
    session():clear_files()
    session():add_files({ "a.lua", "b.lua" })
    session():read_files({ "c.lua", "d.lua" })

    session():drop_files({ "a.lua", "c.lua" })
    assert.are.same({ added = { "b.lua" }, readonly = { "d.lua" } }, session():list_files())

    session():clear_files()
    assert.are.same({ added = {}, readonly = {} }, session():list_files())
  end)

  it("混合交错添加时各 mode 内保持稳定顺序", function()
    session():clear_files()
    session():add_files({ "m1.lua" })
    session():read_files({ "m2.lua" })
    session():add_files({ "m3.lua" })
    session():read_files({ "m4.lua" })

    local files = session():list_files()
    assert.are.same({ "m1.lua", "m3.lua" }, files.added, "added 按交错插入顺序")
    assert.are.same({ "m2.lua", "m4.lua" }, files.readonly, "readonly 按交错插入顺序")
  end)
end)
