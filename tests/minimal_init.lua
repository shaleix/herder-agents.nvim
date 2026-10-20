-- 最小 init（仿 neogit tests/minimal_init.lua）：只做 rtp 装配，不 source 插件、
-- 不跑 plugin.setup —— 各 spec 自行 require("herder-agents") 并按需 setup。
-- plenary 解析次序：已有 rtp → 本机 lazy 目录 → tmp/（ensure_installed 克隆位置）。

local ok_plenary = pcall(require, "plenary")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

if not ok_plenary then
  local candidates = {
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
    root .. "/tmp/plenary/plenary.nvim",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.isdirectory(path) == 1 then
      vim.opt.runtimepath:prepend(path)
      break
    end
  end
end
