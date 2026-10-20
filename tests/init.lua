-- 测试入口（仿 neogit tests/init.lua）：plenary test_harness 跑 tests/specs，
-- sequential（每个 spec 文件一个独立 headless nvim 实例）。
-- 运行：make test（或 TEST_FILES=tests/specs/herder-agents/panes_spec.lua make test）

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

require("tests.util.util").ensure_installed("nvim-lua/plenary.nvim", "tmp/plenary")

local directory = os.getenv("TEST_FILES")
if directory == nil or directory == "" then
  directory = "tests/specs"
end

require("plenary.test_harness").test_directory(directory, {
  minimal_init = "tests/minimal_init.lua",
  sequential = true,
})
