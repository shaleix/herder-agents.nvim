-- prompt 历史读写（ui/history）—— 纯文件 IO 直测：
-- history_file 指到临时路径（before_each/after_each 保存/恢复原值），
-- save 为 read-modify-write 追加、load 容错（缺失/损坏 → 空表）。
-- input_history_view 是 nui 弹窗 UI，不在本 spec 覆盖。

local config = require("herder-agents.config")
local history = require("herder-agents.ui.history")

describe("prompt 历史（ui/history）", function()
  local orig_file

  before_each(function()
    orig_file = config.options.history_file
    config.options.history_file = vim.fn.tempname()
  end)

  after_each(function()
    if vim.fn.filereadable(config.options.history_file) == 1 then
      os.remove(config.options.history_file)
    end
    config.options.history_file = orig_file
  end)

  it("save+load roundtrip：按路径分桶追加，条目含 content/timestamp", function()
    history.save("first", "/proj/a")
    history.save("second", "/proj/a")
    history.save("other", "/proj/b")

    local h = history.load()
    assert.are.equal(2, #h["/proj/a"])
    assert.are.equal("first", h["/proj/a"][1].content)
    assert.are.equal("second", h["/proj/a"][2].content)
    assert.are.equal(1, #h["/proj/b"])
    assert.are.equal("other", h["/proj/b"][1].content)

    -- 时间戳：同路径两条均存在且单调不减
    assert.truthy(h["/proj/a"][1].timestamp)
    assert.truthy(h["/proj/a"][2].timestamp >= h["/proj/a"][1].timestamp)
  end)

  it("save 跨调用持久化：load 重新读文件仍取到全部条目", function()
    history.save("one", "/proj")
    history.save("two", "/proj")

    -- load 不依赖内存态（每次 io.open 重读），等价于进程重启后的行为
    local h = history.load()
    assert.are.same(
      { "one", "two" },
      vim.tbl_map(function(e)
        return e.content
      end, h["/proj"])
    )
  end)

  it("损坏 JSON → load 返回空表；随后 save 覆盖式重建不炸", function()
    vim.fn.writefile({ "not json {{{" }, config.options.history_file)
    assert.are.same({}, history.load())

    history.save("after-corrupt", "/proj")
    local h = history.load()
    assert.are.equal(1, #h["/proj"])
    assert.are.equal("after-corrupt", h["/proj"][1].content)
  end)

  it("文件缺失 → load 返回空表", function()
    assert.falsy(vim.fn.filereadable(config.options.history_file) == 1)
    assert.are.same({}, history.load())
  end)
end)
