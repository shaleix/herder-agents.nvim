-- sessions（prompt 文件附件状态）—— 纯状态直测：
-- add/drop/list/clear 全走 current_session()，无 UI 依赖，headless 直接断言。
-- 路径归一语义：utils.get_relative_path 只在路径以 cwd 开头时剥掉 cwd 前缀。
-- 只读附件通道（read_buffer/readonly）已移除：单一有序相对路径表即全部状态。

local sessions = require("herder-agents.sessions")

describe("sessions 附件列表（单一有序表）", function()
  -- 相对路径 → 绝对路径（get_relative_path 剥 cwd 前缀的逆操作）
  local function abs(rel)
    return vim.fn.getcwd() .. "/" .. rel
  end

  local function session()
    return sessions.current_session()
  end

  it("add→list 保插入顺序；重复 add（含绝对路径拼写）不产生重复条目", function()
    session():clear_files()
    session():add_files({ "a.lua", "b.lua", "c.lua" })
    assert.are.same({ "a.lua", "b.lua", "c.lua" }, session():list_files())

    -- 绝对路径传入同一文件（归一后同路径）→ 去重，不新增
    session():add_files({ abs("b.lua") })
    assert.are.same({ "a.lua", "b.lua", "c.lua" }, session():list_files())
  end)

  it("drop 归一化：存的相对路径、传绝对路径（或反之）都能删掉", function()
    session():clear_files()
    session():add_files({ "x.lua", "y.lua" })

    -- 传绝对路径删相对存储的条目
    session():drop_files({ abs("x.lua") })
    assert.are.same({ "y.lua" }, session():list_files())

    -- 传相对路径删绝对拼写加入的条目
    session():add_files({ abs("z.lua") })
    session():drop_files({ "z.lua" })
    assert.are.same({ "y.lua" }, session():list_files())

    -- 未知路径 no-op
    session():drop_files({ "nope.lua" })
    assert.are.same({ "y.lua" }, session():list_files())
  end)

  it("drop 移除中间项后顺序保持；clear 清空", function()
    session():clear_files()
    session():add_files({ "1.lua", "2.lua", "3.lua", "4.lua" })
    session():drop_files({ "2.lua", "3.lua" })
    assert.are.same({ "1.lua", "4.lua" }, session():list_files())

    session():clear_files()
    assert.are.same({}, session():list_files())
  end)

  it("list_files 返回副本：外部修改不影响内部状态", function()
    session():clear_files()
    session():add_files({ "keep.lua" })
    local files = session():list_files()
    files[1] = "tampered.lua"
    assert.are.same({ "keep.lua" }, session():list_files())
  end)
end)
