-- 测试公共工具（仿 neogit tests/util/util.lua）

local M = {}

M.project_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

--- 快捷键是否已注册（原 smoke 套件的 has_map）
function M.has_map(lhs, mode)
  return vim.fn.maparg(lhs, mode) ~= ""
end

--- 缺依赖时克隆到 tmp/（离线环境应预先放到 rtp 或 tmp/ 下）
---@param repo string 例如 "nvim-lua/plenary.nvim"
---@param dir string 相对仓库根的目标目录，例如 "tmp/plenary"
function M.ensure_installed(repo, dir)
  if pcall(require, "plenary") then
    return
  end
  local target = M.project_dir .. "/" .. dir .. "/" .. repo:match("[^/]+$")
  if vim.fn.isdirectory(target) == 1 then
    vim.opt.runtimepath:prepend(target)
    return
  end
  vim.notify("herder-agents tests: cloning " .. repo .. " -> " .. target, vim.log.levels.INFO)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
  vim.system({ "git", "clone", "--depth", "1", "https://github.com/" .. repo, target }):wait()
  vim.opt.runtimepath:prepend(target)
end

return M
