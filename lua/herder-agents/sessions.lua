-- prompt 文件附件的会话状态（内存态，随 Neovim 生命周期）
-- 文件树（输入弹窗顶部）与提交时的 "Relate file:" 附件块都取材于此；
-- 外部（如 fzf-lua 文件选择器的 ctrl-h）也可调用 current_session():add_files()
local utils = require("herder-agents.utils")

local M = {}

local Session = {}

-- 内部为单个有序 entries 数组，保插入顺序；路径统一按 utils.get_relative_path 归一比较。
-- entry 形如 { path = <归一化相对路径>, mode = "added"|"readonly" }，
-- add/read 只翻 mode 不动位置，drop 按 mode 无关移除。
local function create(session_name)
  local s = {
    name = session_name,
    entries = {},
  }
  setmetatable(s, { __index = Session })
  return s
end

---按归一化路径查找 entry 所在下标（找不到返回 nil）
---@param relative_path string
---@return integer|nil
local function find(self, relative_path)
  for i, entry in ipairs(self.entries) do
    if entry.path == relative_path then
      return i
    end
  end
  return nil
end

function Session:clear_files()
  self.entries = {}
end

function Session:list_files()
  local files = {
    added = {},
    readonly = {},
  }
  for _, entry in ipairs(self.entries) do
    table.insert(files[entry.mode], entry.path)
  end
  return files
end

---@param file_paths string[]
function Session:add_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    local relative_path = utils.get_relative_path(file_path)

    -- 已存在（任一 mode）→ 只翻回 added，保持原插入位置；否则追加（天然去重）
    local i = find(self, relative_path)
    if i then
      self.entries[i].mode = "added"
    else
      table.insert(self.entries, { path = relative_path, mode = "added" })
    end
  end
end

---@param file_paths string[]
function Session:read_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    local relative_path = utils.get_relative_path(file_path)

    -- 已存在（任一 mode）→ 只翻成 readonly，保持原插入位置；否则追加（天然去重）
    local i = find(self, relative_path)
    if i then
      self.entries[i].mode = "readonly"
    else
      table.insert(self.entries, { path = relative_path, mode = "readonly" })
    end
  end
end

function Session:drop_files(file_paths)
  for _, file_path in ipairs(file_paths) do
    -- 与 add/read 同一归一化：传绝对路径也能删掉以相对路径存的条目
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
