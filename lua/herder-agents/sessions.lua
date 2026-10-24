-- prompt 文件附件的会话状态（内存态，随 Neovim 生命周期）
-- 文件树（输入弹窗顶部）与提交时的 "Relate file:" 附件块都取材于此；
-- 外部（如 fzf-lua 文件选择器的 ctrl-h）也可调用 current_session():add_files()
-- （只读附件通道 read_buffer/readonly 已移除：下游 chat 树与附件块本就同权，
--   单一附件列表即全部语义）
local utils = require("herder-agents.utils")

local M = {}

local Session = {}

-- 内部为单个有序相对路径数组，保插入顺序；路径统一按 utils.get_relative_path
-- 归一比较（add 去重、drop 跨绝对/相对拼写可删）。
local function create(session_name)
  local s = {
    name = session_name,
    entries = {},
  }
  setmetatable(s, { __index = Session })
  return s
end

---按归一化路径查找下标（找不到返回 nil）
---@param relative_path string
---@return integer|nil
local function find(self, relative_path)
  for i, path in ipairs(self.entries) do
    if path == relative_path then
      return i
    end
  end
  return nil
end

function Session:clear_files()
  self.entries = {}
end

---会话附件列表（插入顺序的相对路径副本）
function Session:list_files()
  local files = {}
  for _, path in ipairs(self.entries) do
    table.insert(files, path)
  end
  return files
end

---@param file_paths string[]
function Session:add_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    local relative_path = utils.get_relative_path(file_path)
    -- 已存在（含不同拼写归一后相同）→ 幂等 no-op；否则追加
    if not find(self, relative_path) then
      table.insert(self.entries, relative_path)
    end
  end
end

function Session:drop_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    -- 与 add 同一归一化：传绝对路径也能删掉以相对路径存的条目
    local i = find(self, utils.get_relative_path(file_path))
    if i then
      table.remove(self.entries, i)
    end
  end
end

local current = create()

M.current_session = function()
  return current
end

return M
