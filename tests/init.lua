-- 测试入口（仿 neogit tests/init.lua）：plenary test_harness 跑 tests/specs，
-- sequential（每个 spec 文件一个独立 headless nvim 实例）。
-- 运行：make test（或 TEST_FILES=<单个文件或目录> make test；多个目标由
-- Makefile 逐个起 nvim —— test_directory 收尾即 qa，单进程循环跑不完多个）。
-- 注意：TEST_FILES 必须指向真实存在的路径 —— 路径不存在时本入口【硬失败】，
-- 否则 plenary 会对无效路径静默跑 0 个 spec 并以 0 退出（假绿）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

require("tests.util.util").ensure_installed("nvim-lua/plenary.nvim", "tmp/plenary")

local targets = {}
local raw = os.getenv("TEST_FILES")
if raw == nil or raw == "" then
  targets = { "tests/specs" }
else
  for part in raw:gmatch("[^%s,]+") do
    targets[#targets + 1] = part
  end
end
if #targets > 1 then
  print("TEST_FILES 多目标请在 Makefile 层循环（每个目标一个 nvim；test_directory 收尾即 qa）——本进程只跑第一个")
end
local target = targets[1]
if vim.fn.filereadable(target) == 0 and vim.fn.isdirectory(target) == 0 then
  -- headless -S 下 error() 只打日志不退出（进程挂住），必须 cquit 显式失败退出
  print(
    ("TEST_FILES 路径不存在: %s（plenary 对无效路径会静默跑 0 个 spec 假绿，提前拦截）"):format(
      target
    )
  )
  vim.cmd("cquit 1")
end

require("plenary.test_harness").test_directory(target, {
  minimal_init = "tests/minimal_init.lua",
  sequential = true,
})
